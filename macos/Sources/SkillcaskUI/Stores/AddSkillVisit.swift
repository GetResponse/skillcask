import Foundation
import Observation
import SkillcaskCore

/// One visit to the Add Skill sheet (S8, S11): its search, its run, and what it added. The sheet stays open after
/// an add that exits 0, so several skills can be added without searching again:
///
/// - An add runs through `SheetRun` without a toast. Afterwards the results are as they were, the selection stays
///   on the added row (whose Installed marker follows the scope's refresh), `footer` says what was added, and the
///   close button reads Done.
/// - One add at a time: the next one starts only after the run ended, and never the same `add` again while the
///   selection stays on the added row (`SearchStore.isRepeat`).
/// - A failure stays in the preview pane as before; what was added before it stays counted.
/// - An add names its skills from the preview. Once the scope's refresh after it has landed, a skill the scope
///   does not have is no longer claimed, counted or selected (`settle`).
/// - When the sheet goes away (`cancelOrClose(runner:)`, `disappeared(runner:)`), the one toast shows (the add's
///   own after one add, a summary after several) and the skill list selects the last added skill.
///
/// The sheet draws what this says and calls its actions; it decides nothing itself. One per sheet presentation,
/// held by the sheet as `@State`.
@MainActor @Observable final class AddSkillVisit {
    /// One add that exited 0.
    struct Added: Hashable, Sendable {
        let package: String
        /// The skills as agents see them; empty when the package's preview listed none, or none of them is in the
        /// scope (`addedNothing`).
        var skills: [String]
        /// `Added jira-syntax and jira-communication (4.2.0)`, from the CLI's `added` line.
        var text: String
        /// The run's `ActivityEntry`, for the toast's "Show details".
        let runID: UUID?
        /// The scope's refresh after the add has none of the skills it named: it counts for nothing.
        var addedNothing = false
    }

    /// What takes the keyboard: the header's field, or the results list.
    enum Focus: Hashable, Sendable {
        case field
        case results
    }

    /// The footer's leading content.
    enum Footer: Hashable {
        /// Nothing added yet: what Add writes, for the scope.
        case note(String)
        /// What the last add said, with its skill names as the toast emphasizes them, and from the second add on
        /// the count of skills (`· 3 skills added`), which the footer never truncates.
        case added(text: String, emphasis: [String], count: String?)
    }

    let search: SearchStore
    /// The sheet's mutation: progress in place, Cancel while running (`SheetRun`).
    let run = SheetRun()
    /// The adds of this visit that exited 0, oldest first.
    private(set) var added: [Added] = []
    /// Where the keyboard goes when the run that just ended gives the sheet back: the results list, on the added
    /// row, after an add that exited 0 (Down and Return add the next result); the field after a failure, a cancel,
    /// or an add of a typed source, which has no list. Set when a run starts and when it succeeds; the sheet reads
    /// it once, when the run ends.
    private(set) var focusAfterRun: Focus = .field
    /// What VoiceOver hears when the run that just ended gives the sheet back: `status` after an add that exited
    /// 0, nothing otherwise. Set and read as `focusAfterRun`.
    private(set) var announcementAfterRun: String?
    /// Closes the sheet (`AppStore.dismiss`).
    @ObservationIgnored private let onClose: () -> Void
    @ObservationIgnored private var isClosed = false
    /// This visit's runs, each ending when the scope's refresh after it has landed.
    @ObservationIgnored private var runs: [Task<Void, Never>] = []
    /// The selection an add made after the sheet was gone; that add's task ends with it.
    @ObservationIgnored private var lateSelection: Task<Void, Never>?
    /// Where in `added` each run that exited 0 stands, until its refresh has landed (`settle`).
    @ObservationIgnored private var unsettled: [UUID: Int] = [:]

    init(search: SearchStore, onClose: @escaping () -> Void = {}) {
        self.search = search
        self.onClose = onClose
    }

    // MARK: - Derived

    /// Add needs a loaded preview and a buildable command, nothing running, and not the add that just succeeded
    /// for this selection (`SearchStore.isRepeat`).
    var canAdd: Bool {
        guard !run.isRunning, search.command != nil, !search.isRepeat else { return false }
        if case .loaded = search.preview { return true }
        return false
    }

    /// The skills added in this visit, each counted once however often its package was added; a package whose
    /// skills are not known counts as one, an add that added nothing as none.
    var skillCount: Int {
        Set(added.filter { !$0.addedNothing }.flatMap { $0.skills.isEmpty ? [$0.package] : $0.skills }).count
    }

    /// The count beside the last add's words, from the second add on, while there is something to count.
    private var countNote: String? {
        added.count > 1 && skillCount > 0 ? AddSkillCopy.addedSoFar(skillCount) : nil
    }

    /// What the visit added, in one sentence: the footer's accessibility label and VoiceOver's announcement after
    /// an add. Nil before the first one.
    var status: String? {
        guard let last = added.last else { return nil }
        return AddSkillCopy.status(last.text, count: countNote)
    }

    var footer: Footer {
        guard let last = added.last else {
            return .note(search.store.scope.isPersonal ? AddSkillCopy.footerPersonal : AddSkillCopy.footerProject)
        }
        return .added(text: last.text, emphasis: last.skills, count: countNote)
    }

    /// The footer's close button: Cancel (it stops a run in flight), Done once something was added.
    var closeTitle: String {
        run.isRunning || added.isEmpty ? SheetCopy.cancel : AddSkillCopy.done
    }

    // MARK: - Actions

    /// Runs the `add` of the current choices through `runner`, without a toast; on exit 0 the sheet stays as it is
    /// and the add is counted. Returns nil when Add is not available (`canAdd`) or the app runs something else;
    /// else the task that ends when the scope's refresh after the run has landed.
    @discardableResult func add(runner: ActionRunner) -> Task<Void, Never>? {
        guard canAdd, let command = search.command, let spec = search.selectedSpec else { return nil }
        let skills = addedNames
        let package = spec.base
        let lockName = spec.package
        let choices = search.choices
        let ticket = UUID()
        focusAfterRun = .field
        announcementAfterRun = nil
        let run = run.start(
            command, title: AddSkillCopy.adding(package), failure: AddSkillCopy.couldNotAdd(package),
            outcome: { _ in AddSkillCopy.added(package: package) },
            report: { _, transcript in AddSkillCopy.added(package: package, skills: skills, transcript: transcript) },
            emphasis: skills, announce: false, in: search.store, runner: runner,
            onSuccess: {
                self.succeeded(choices, package: package, skills: skills, runner: runner)
                self.unsettled[ticket] = self.added.count - 1
            })
        guard let run else { return nil }
        let settled = Task {
            await run.value
            settle(ticket, package: lockName)
        }
        runs.append(settled)
        return Task {
            await settled.value
            await lateSelection?.value
        }
    }

    /// The scope's refresh after an add landed: the add keeps the skills it named that the scope has under its
    /// package. When some are missing (skills.toml renames the skill, so `status` knows another name and the add
    /// changed nothing), its words fall back to the package's, and with none left it counts for nothing. A refresh
    /// that failed says nothing, and the add's words stand.
    private func settle(_ ticket: UUID, package: String) {
        let store = search.store
        guard let index = unsettled.removeValue(forKey: ticket), store.refreshError == nil,
            let entries = store.snapshot?.entries
        else { return }
        let present = Set(entries.filter { $0.package?.lowercased() == package }.map(\.name))
        let named = added[index].skills
        let found = named.filter(present.contains)
        guard found != named else { return }
        added[index].skills = found
        added[index].text = AddSkillCopy.added(package: package)
        added[index].addedNothing = found.isEmpty
    }

    private func succeeded(_ choices: SearchStore.Choices, package: String, skills: [String], runner: ActionRunner) {
        added.append(
            Added(
                package: package, skills: skills, text: run.headline ?? AddSkillCopy.added(package: package),
                runID: run.runID))
        search.added(choices)
        focusAfterRun = search.selectedResult == nil ? .field : .results
        announcementAfterRun = status
        // The sheet went away under the run (its scope left the sidebar): nothing will close it again, so the
        // visit's toast and selection are done over, with this add in them.
        if isClosed {
            lateSelection = conclude(runner: runner)
        }
    }

    /// The footer's Cancel or Done, and Esc: stops the run while one is in flight, else closes the sheet, once,
    /// with what the visit added (`close(runner:)`, whose task it returns).
    @discardableResult func cancelOrClose(runner: ActionRunner) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        if run.canCancel {
            run.cancel()
            return nil
        }
        let selection = close(runner: runner)
        onClose()
        return selection
    }

    /// The sheet left the screen, however it was dismissed: stops the pending search and the preview's download
    /// (the consent answer still lands), and shows what the visit added if no button did (`close(runner:)`).
    @discardableResult func disappeared(runner: ActionRunner) -> Task<Void, Never>? {
        search.end()
        return close(runner: runner)
    }

    /// The sheet closes: after one add, that add's toast; after several, one summary; and the skill list selects
    /// the last add's first skill (the list is single-selection, `ScopeStore.selection` is one id). Once per
    /// visit; returns the selection's task, nil when nothing was added or the last add's skills are not known.
    @discardableResult func close(runner: ActionRunner) -> Task<Void, Never>? {
        guard !isClosed else { return nil }
        isClosed = true
        return conclude(runner: runner)
    }

    /// The visit's one toast and its selection, from everything added so far. The skill is selected at once, and
    /// again when the refreshes after this visit's runs have landed if none is selected then: a refresh that read
    /// the scope before the last add drops a selection it does not know (`ScopeStore.rebuild`).
    private func conclude(runner: ActionRunner) -> Task<Void, Never>? {
        guard let last = added.last else { return nil }
        if added.count == 1 || skillCount == 0 {
            runner.announce(last.text, emphasis: last.skills, id: last.runID ?? UUID())
        } else {
            runner.announce(AddSkillCopy.summary(done: skillCount, scope: ShellCopy.name(of: search.store.scope)))
        }
        guard let skill = last.skills.first else { return nil }
        let store = search.store
        let runs = runs
        return Task {
            await store.select(skill)
            for run in runs {
                await run.value
            }
            // The last add may have settled meanwhile: only a skill it still names is selected.
            if store.selection == nil, let skill = self.added.last?.skills.first {
                await store.select(skill)
            }
        }
    }

    /// The skills as agents will see them: the chosen ones, the clashing one under its new name.
    private var addedNames: [String] {
        let rename = search.clash.map { ($0.skill, search.renameTo.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return search.chosenSkills.map { name in
            if let rename, rename.0 == name, !rename.1.isEmpty { rename.1 } else { name }
        }
    }

    // MARK: - Previews

    /// Previews: the sheet after `added`, the last of them for the selection, with no command behind them.
    func preload(added: [Added]) {
        self.added = added
        if !added.isEmpty {
            search.added(search.choices)
        }
    }
}
