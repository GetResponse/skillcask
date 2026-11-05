import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The Add Skill sheet (S8, F2; AddSkill and AddSkill-States boards). The header holds the title and the field
/// (a term or a source), with the sources searched under it; the body splits into the results (`ResultsColumn`)
/// and the selection's preview (`ResultPreview`); the footer says what Add writes and holds Cancel and Add.
///
/// The state lives in a `SearchStore` (search, consent, preview, rule, skills, rename) and the run in a `SheetRun`:
/// Add shows its progress in place of the body, Cancel stops it, exit 0 closes the sheet with the runner's toast
/// and selects the first new skill, and a failure stays in the preview pane with the CLI's hint as the action
/// until the field or the selection changes.
///
/// Resizable from `Size.addSkillSheet` up to `maximum`, opening at `ideal` (`AddSkillSheetHost` supplies both;
/// previews and renders keep the defaults, so they draw at the board size). The results column widens with the
/// sheet (`ResultsColumn.width(in:)`), the preview takes the rest (gap G16).
struct AddSkillSheet: View {
    /// What the previews draw in place of a live run.
    enum PreviewState: Sendable {
        /// The progress block with these lines, as if Add were running.
        case running(AddSkillProgress.Model)
        /// The failure of an Add, as if one had just ended so.
        case addFailure(UserMessage)
    }

    let store: ScopeStore
    /// Closes the sheet (`AppStore.presentedSheet = nil`).
    let onClose: () -> Void

    @Environment(ActionRunner.self) private var runner
    @State private var search: SearchStore
    /// The sheet's mutation: progress in place, Cancel while running, close on success (`SheetRun`).
    @State private var run = SheetRun()
    /// The spec of the Add whose failure is on screen; nil once the field or the selection moved on.
    @State private var failedSpec: String?
    private let previewState: PreviewState?
    /// The size the sheet opens at.
    private let ideal: CGSize
    /// The most the sheet grows to.
    private let maximum: CGSize

    /// The live sheet; `query` is the text the field starts with ("Find “…” in sources"), nil for an empty field.
    init(
        query: String?, store: ScopeStore, ideal: CGSize = Size.addSkillSheet,
        maximum: CGSize = Size.addSkillSheetMax, onClose: @escaping () -> Void
    ) {
        self.store = store
        self.onClose = onClose
        self.ideal = ideal
        self.maximum = maximum
        _search = State(initialValue: SearchStore(store: store, query: query))
        previewState = nil
    }

    /// Previews: a preloaded `search`, and optionally a run in flight or a failed Add.
    init(
        search: SearchStore, previewState: PreviewState? = nil, ideal: CGSize = Size.addSkillSheet,
        maximum: CGSize = Size.addSkillSheetMax, onClose: @escaping () -> Void = {}
    ) {
        store = search.store
        self.onClose = onClose
        self.ideal = ideal
        self.maximum = maximum
        _search = State(initialValue: search)
        self.previewState = previewState
        if case .addFailure = previewState {
            _failedSpec = State(initialValue: search.selectedSpec?.base)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            Group {
                if let progress {
                    AddSkillProgress(model: progress)
                } else {
                    AddSkillColumns {
                        ResultsColumn(search: search)
                        Rectangle()
                            .fill(Color.separator)
                            .frame(width: Size.hairline)
                        ResultPreview(search: search, addFailure: addFailure, onRetryAdd: add)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            hairline
            footer
        }
        .frame(
            minWidth: Size.addSkillSheet.width, idealWidth: ideal.width, maxWidth: maximum.width,
            minHeight: Size.addSkillSheet.height, idealHeight: ideal.height, maxHeight: maximum.height
        )
        .background(Color.surfaceWindow)
        .interactiveDismissDisabled(isRunning)
        .task { search.begin() }
        // Closing the sheet stops the pending search and the preview's download (the consent answer still lands).
        .onDisappear { search.end() }
        .onChange(of: search.query) { failedSpec = nil }
        .onChange(of: search.selection) { failedSpec = nil }
    }

    // MARK: - Derived

    private var isRunning: Bool {
        if case .running = previewState { return true }
        return run.isRunning
    }

    private var progress: AddSkillProgress.Model? {
        if case .running(let model) = previewState {
            return model
        }
        guard run.isRunning else { return nil }
        return run.action.map(AddSkillProgress.Model.init)
            ?? AddSkillProgress.Model(title: runTitle ?? "", startedAt: Date(), lines: [])
    }

    private var runTitle: String? {
        if case .running(let title) = run.phase { title } else { nil }
    }

    private var addFailure: UserMessage? {
        guard failedSpec != nil else { return nil }
        if case .addFailure(let message) = previewState {
            return message
        }
        return run.failure
    }

    private var addTitle: String {
        if let clash = search.clash {
            let name = search.renameTo.trimmingCharacters(in: .whitespacesAndNewlines)
            return AddSkillCopy.addAs(name.isEmpty ? clash.suggestion : name)
        }
        return AddSkillCopy.addButton(skills: search.info.map { _ in search.chosenSkills.count })
    }

    /// Add needs a loaded preview and a buildable command, and nothing running.
    private var canAdd: Bool {
        guard !isRunning, search.command != nil else { return false }
        if case .loaded = search.preview { return true }
        return false
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            Text(AddSkillCopy.title(scopeName: ShellCopy.name(of: store.scope)))
                .font(Font.Token.headline)
                .foregroundStyle(Color.textPrimary)
            if !isRunning {
                SearchField(query: $search.query)
                summary
            }
        }
        .padding(.top, Spacing.l)
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `3 of 20 results`, the source chips and blocked pills (`SourceFilterBar`), `Sorted by installs`: once results
    /// are in, or while a source filter is active (so its chip stays even when the new query found nothing).
    @ViewBuilder private var summary: some View {
        if Self.showsSummary(results: search.results, filter: search.sourceFilter) {
            HStack(spacing: Spacing.s) {
                Text(AddSkillCopy.results(shown: search.filteredResults.count, total: search.totalResultCount))
                    .fixedSize()
                SourceFilterBar(search: search)
                if search.isSortedByInstalls {
                    Text(AddSkillCopy.sortedByInstalls)
                        .fixedSize()
                }
            }
            .font(Font.Token.callout)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
        }
    }

    /// The summary row shows for a loaded document with results, or with a source filter set.
    nonisolated static func showsSummary(results: SearchStore.Results, filter: String?) -> Bool {
        guard case .loaded(let document) = results else { return false }
        return !document.results.isEmpty || filter != nil
    }

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            if !isRunning {
                Text(store.scope.isPersonal ? AddSkillCopy.footerPersonal : AddSkillCopy.footerProject)
                    .font(Font.Token.callout)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: Spacing.s)
            Button(SheetCopy.cancel, action: cancel)
                .keyboardShortcut(.cancelAction)
            Button(addTitle, action: add)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .disabled(!canAdd)
        }
        .padding(.vertical, Spacing.m)
        .padding(.horizontal, Spacing.xl)
        .background(Color.surfaceGrouped)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(height: Size.hairline)
    }

    // MARK: - Actions

    /// Stops the run while one is in flight, else closes the sheet.
    private func cancel() {
        if run.canCancel {
            run.cancel()
        } else {
            onClose()
        }
    }

    /// Runs `add` through the runner; on exit 0 the sheet closes and the first new skill is selected. The skill
    /// list is single-selection (`ScopeStore.selection` is one id), so the other new rows are not selected.
    private func add() {
        guard canAdd, let command = search.command, let spec = search.selectedSpec else { return }
        let skills = addedNames
        let package = spec.base
        let first = skills.first
        let store = store
        failedSpec = spec.base
        run.start(
            command, title: AddSkillCopy.adding(spec.base), failure: AddSkillCopy.couldNotAdd(spec.base),
            outcome: { _ in AddSkillCopy.added(package: package) },
            report: { _, transcript in Self.toast(package: package, skills: skills, transcript: transcript) },
            emphasis: skills, in: store, runner: runner,
            onSuccess: {
                onClose()
                if let first {
                    Task { await store.select(first) }
                }
            })
    }

    /// The skills as agents will see them: the chosen ones, the clashing one under its new name.
    private var addedNames: [String] {
        let rename = search.clash.map { ($0.skill, search.renameTo.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return search.chosenSkills.map { name in
            if let rename, rename.0 == name, !rename.1.isEmpty { rename.1 } else { name }
        }
    }

    /// `Added jira-syntax and jira-communication (4.2.0)`; `Added <package>` when the skills are not known.
    nonisolated static func toast(package: String, skills: [String], version: String?) -> String {
        guard let version, !skills.isEmpty else { return AddSkillCopy.added(package: package) }
        return OutcomeCopy.added(skills, version: version)
    }

    /// The toast from the CLI's own `added <package> = "<constraint>" (<version>)` line (`src/commands.rs`
    /// `finish_add`): the version it locked, which `info` cannot promise before the run (a GitHub or git ref
    /// locks a commit and prints its first 12 hex digits, `src/github.rs` 278, `src/git.rs` 635).
    nonisolated static func toast(package: String, skills: [String], transcript: [OutputLine]) -> String {
        let version = MutationReport(verbLines: ActionRunner.stdout(of: transcript)).addedVersions.values.first
        return toast(package: package, skills: skills, version: version)
    }
}

/// The board's field: the magnifier, the system text field, and the source shapes at its trailing end, with the
/// accent ring while it has focus.
private struct SearchField: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool

    /// The board's 30 pt field (`Size.search` is the list's 26 pt one).
    static let height = Size.search + Spacing.xs
    /// The focus ring's `box-shadow: 0 0 0 3px var(--accent-soft)`.
    static let ringWidth: CGFloat = 3

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)
                .accessibilityHidden(true)
            TextField(AddSkillCopy.fieldLabel, text: $query)
                .textFieldStyle(.plain)
                .font(Font.Token.body)
                .focused($isFocused)
                .accessibilityLabel(AddSkillCopy.fieldLabel)
            HStack(spacing: Spacing.xs) {
                Text(AddSkillCopy.sourceHint)
                    .font(Font.Token.caption)
                Text(AddSkillCopy.sourceShapes)
                    .font(Font.Token.monoSmall)
            }
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.cardGap)
        .frame(height: Self.height)
        .background(Color.controlFill, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .strokeBorder(isFocused ? Color.accent : Color.controlBorder, lineWidth: Size.hairline)
        )
        .background(
            RoundedRectangle(cornerRadius: Radius.m + Self.ringWidth, style: .continuous)
                .fill(isFocused ? Color.accentSoft : Color.clear)
                .padding(-Self.ringWidth)
        )
        .onAppear { isFocused = true }
    }
}
