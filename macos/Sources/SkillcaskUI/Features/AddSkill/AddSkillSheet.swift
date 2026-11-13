import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The Add Skill sheet (S8, F2; AddSkill and AddSkill-States boards). The header holds the title and the field
/// (a term or a source), with the sources searched under it; the body splits into the results (`ResultsColumn`)
/// and the selection's preview (`ResultPreview`); the footer says what Add writes, or what was added, and holds
/// Cancel (Done after an add) and Add.
///
/// The state lives in a `SearchStore` (search, consent, preview, rule, skills, rename) and the run in the
/// `AddSkillVisit`'s `SheetRun`: Add shows its progress over the body, Cancel stops it, and a failure stays in the
/// preview pane with the CLI's hint as the action until the field or the selection changes. Exit 0 leaves the sheet
/// open (S11): the results come back as they were, with the selection and the keyboard on the added row, now
/// marked Installed; the footer says what was added; and the next add can follow. Closing the sheet then shows the
/// toast and selects the last added skill. The visit decides all of that; this view draws `AddSkillVisit.footer`
/// and `closeTitle`, moves the keyboard to `focusAfterRun` when a run ends, and calls `add(runner:)`,
/// `cancelOrClose(runner:)` and `disappeared(runner:)`.
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
        /// The sheet after these adds, the last of them for the selection.
        case added([AddSkillVisit.Added])
    }

    let store: ScopeStore

    @Environment(ActionRunner.self) private var runner
    @State private var search: SearchStore
    /// The sheet's run and what it added so far; it shares `search`.
    @State private var visit: AddSkillVisit
    /// The spec of the Add whose failure is on screen; nil once the field or the selection moved on.
    @State private var failedSpec: String?
    @FocusState private var focus: AddSkillVisit.Focus?
    private let previewState: PreviewState?
    /// The size the sheet opens at.
    private let ideal: CGSize
    /// The most the sheet grows to.
    private let maximum: CGSize

    /// The live sheet; `query` is the text the field starts with ("Find “…” in sources"), nil for an empty field.
    /// `onClose` closes the sheet (`AppStore.presentedSheet = nil`); the visit calls it.
    init(
        query: String?, store: ScopeStore, ideal: CGSize = Size.addSkillSheet,
        maximum: CGSize = Size.addSkillSheetMax, onClose: @escaping () -> Void
    ) {
        self.store = store
        self.ideal = ideal
        self.maximum = maximum
        let search = SearchStore(store: store, query: query)
        _search = State(initialValue: search)
        _visit = State(initialValue: AddSkillVisit(search: search, onClose: onClose))
        previewState = nil
    }

    /// Previews: a preloaded `search`, and optionally a run in flight, a failed Add or the adds so far.
    init(
        search: SearchStore, previewState: PreviewState? = nil, ideal: CGSize = Size.addSkillSheet,
        maximum: CGSize = Size.addSkillSheetMax, onClose: @escaping () -> Void = {}
    ) {
        store = search.store
        self.ideal = ideal
        self.maximum = maximum
        _search = State(initialValue: search)
        let visit = AddSkillVisit(search: search, onClose: onClose)
        if case .added(let added) = previewState {
            visit.preload(added: added)
        }
        _visit = State(initialValue: visit)
        self.previewState = previewState
        if case .addFailure = previewState {
            _failedSpec = State(initialValue: search.selectedSpec?.base)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline
            // The columns stay in the hierarchy under the progress, hidden and inert: when the run ends the list is
            // the one that was there, at the same scroll position.
            ZStack {
                AddSkillColumns {
                    ResultsColumn(search: search, focus: $focus)
                    Rectangle()
                        .fill(Color.separator)
                        .frame(width: Size.hairline)
                    ResultPreview(search: search, addFailure: addFailure, onRetryAdd: add)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .opacity(progress == nil ? 1 : 0)
                .disabled(progress != nil)
                .accessibilityHidden(progress != nil)
                if let progress {
                    AddSkillProgress(model: progress)
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
        .onDisappear { visit.disappeared(runner: runner) }
        .onChange(of: visit.run.isRunning) { _, isRunning in
            guard !isRunning else { return }
            let target = visit.focusAfterRun
            let said = visit.announcementAfterRun
            // The field comes back and the columns are enabled again in this same update; the keyboard moves once
            // they are there. VoiceOver hears what was added after that move, which would cut it off.
            Task { @MainActor in
                focus = target
                if let said {
                    AccessibilityNotification.Announcement(said).post()
                }
            }
        }
        .onChange(of: search.query) { failedSpec = nil }
        .onChange(of: search.selection) { failedSpec = nil }
    }

    // MARK: - Derived

    private var isRunning: Bool {
        if case .running = previewState { return true }
        return visit.run.isRunning
    }

    private var progress: AddSkillProgress.Model? {
        if case .running(let model) = previewState {
            return model
        }
        guard visit.run.isRunning else { return nil }
        return visit.run.action.map(AddSkillProgress.Model.init)
            ?? AddSkillProgress.Model(title: runTitle ?? "", startedAt: Date(), lines: [])
    }

    private var runTitle: String? {
        if case .running(let title) = visit.run.phase { title } else { nil }
    }

    private var addFailure: UserMessage? {
        guard failedSpec != nil else { return nil }
        if case .addFailure(let message) = previewState {
            return message
        }
        return visit.run.failure
    }

    private var addTitle: String {
        if let clash = search.clash {
            let name = search.renameTo.trimmingCharacters(in: .whitespacesAndNewlines)
            return AddSkillCopy.addAs(name.isEmpty ? clash.suggestion : name)
        }
        return AddSkillCopy.addButton(skills: search.info.map { _ in search.chosenSkills.count })
    }

    /// `AddSkillVisit.canAdd`, and no preview of a run on screen.
    private var canAdd: Bool {
        !isRunning && visit.canAdd
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            Text(AddSkillCopy.title(scopeName: ShellCopy.name(of: store.scope)))
                .font(Font.Token.headline)
                .foregroundStyle(Color.textPrimary)
            if !isRunning {
                // Before the first run the field appearing is the sheet opening; later it comes back after a run,
                // and the keyboard goes where the visit says (`onChange` above).
                SearchField(query: $search.query, focus: $focus, takesFocusOnAppear: visit.run.phase == .idle)
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
                switch visit.footer {
                case .note(let note):
                    Text(note)
                        .font(Font.Token.callout)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                case .added(let text, let emphasis, let count):
                    added(text, emphasis: emphasis, count: count)
                }
            }
            Spacer(minLength: Spacing.s)
            Button(visit.closeTitle) { visit.cancelOrClose(runner: runner) }
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

    /// What the last add said, worded and styled as its toast (names semibold, up to two lines), then the count,
    /// which never gives way: a long list of names truncates before it. One element for VoiceOver, read as
    /// `AddSkillVisit.status`.
    private func added(_ text: String, emphasis: [String], count: String?) -> some View {
        HStack(spacing: Spacing.s) {
            StatusDot(.ok)
            Text(Toast.label(text, emphasis: emphasis))
                .font(Font.Token.callout)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(Toast.lineLimit)
            if let count {
                Text(count)
                    .font(Font.Token.callout)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(visit.status ?? text)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(height: Size.hairline)
    }

    // MARK: - Actions

    /// Runs `add` through the runner (`AddSkillVisit.add(runner:)`); on exit 0 the sheet stays open.
    private func add() {
        guard canAdd, let spec = search.selectedSpec else { return }
        failedSpec = spec.base
        visit.add(runner: runner)
    }
}

/// The board's field: the magnifier, the system text field, and the source shapes at its trailing end, with the
/// accent ring while it has focus.
private struct SearchField: View {
    @Binding var query: String
    /// The sheet's keyboard focus, shared with the results list.
    @FocusState.Binding var focus: AddSkillVisit.Focus?
    /// The field appearing is the sheet opening: it takes the keyboard.
    let takesFocusOnAppear: Bool

    private var isFocused: Bool {
        focus == .field
    }

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
                .focused($focus, equals: .field)
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
        .onAppear {
            if takesFocusOnAppear {
                focus = .field
            }
        }
    }
}
