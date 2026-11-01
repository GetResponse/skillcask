import SkillcaskDomain
import SwiftUI

/// The Scope Overview (S1, Overview and Overview-States boards): what the detail column shows when no row is
/// selected. A header on the window surface with the scope's name, its path, "Reveal in Finder", the agent pills
/// and the health strip; then, on the grouped surface, whatever `OverviewState` says: the six cards in a
/// rows of two (two columns that become one when the column is narrower than `twoColumnMinWidth`), their quiet
/// one-line forms in a healthy project, the skeleton while loading, the Set Up block for a folder without
/// skills.toml, or the not-managed banner and the add-a-project hint when the sidebar has no project.
struct ScopeOverviewView: View {
    let store: ScopeStore
    /// The sidebar's manifest check; false shows the Set Up block.
    var isSetUp = true
    /// Previews: the partial-refresh strip starts with its Details open.
    var showsPartialDetails = false

    @Environment(ActionRunner.self) private var runner
    @Environment(AppStore.self) private var app

    /// Two cards of the list column's minimum (300) with the grid gap and the column padding on both sides: the
    /// Overview board's 700 pt column (cards 321 wide) keeps two, the 960 pt window's 380 pt column drops to one.
    static let twoColumnMinWidth = 2 * Size.listMinWidth + Spacing.cardGap + 2 * Size.columnPadding

    /// The Overview board's grid gap (`gap: 12px`, Overview) is `Spacing.cardGap` (10, Overview-States): the
    /// token wins.
    static let gridGap = Spacing.cardGap
    /// The header's `padding: 18px 24px 14px` and `gap: 2px` between name and path; off the scale, so named.
    static let headerTopPadding: CGFloat = 18
    static let headerBottomPadding: CGFloat = 14
    static let titleGap: CGFloat = 2
    /// The strip's `gap: 14px` between counts and `gap: 5px` between a dot and its words; off the scale.
    static let stripGap: CGFloat = 14
    static let stripDotGap: CGFloat = 5
    /// Overview-States Loading: the skeleton bar after "Checking this project…".
    static let loadingBarWidth: CGFloat = 120

    var body: some View {
        let state = self.state
        VStack(spacing: 0) {
            header(state)
            Rectangle()
                .fill(Color.separator)
                .frame(height: Size.hairline)
            GeometryReader { proxy in
                ScrollView {
                    content(state, columns: columns(for: proxy.size.width))
                        .padding(.horizontal, Size.columnPadding)
                        .padding(.vertical, Spacing.l)
                }
            }
            .background(Color.surfaceGrouped)
        }
    }

    // MARK: - Derived

    private var state: OverviewState {
        OverviewState.resolve(
            snapshot: store.snapshot, presentation: store.presentation, isSetUp: isSetUp,
            isPersonal: store.scope.isPersonal, hasProjects: !app.projects.isEmpty)
    }

    static func columnCount(for width: CGFloat) -> Int {
        width >= twoColumnMinWidth ? 2 : 1
    }

    /// A project with nothing to act on: Health, Updates and Security all collapse, so Sources, Policy and Agents
    /// take their one-line forms too (Overview-States Healthy: "cards collapse to one line each").
    static func isQuiet(_ snapshot: ScopeSnapshot) -> Bool {
        HealthCard.isCollapsed(snapshot) && UpdatesCard.isCollapsed(snapshot) && SecurityCard.isCollapsed(snapshot)
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: Self.gridGap, alignment: .top),
            count: Self.columnCount(for: width))
    }

    /// Reveal in Finder: not while loading and not for My Skills (Overview-States draws neither).
    private func showsReveal(_ state: OverviewState) -> Bool {
        if case .loading = state { return false }
        return !store.scope.isPersonal
    }

    // MARK: - Header

    /// `padding: 18px 24px 14px; gap: 10px` on the window surface.
    private func header(_ state: OverviewState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            HStack(alignment: .center, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Self.titleGap) {
                    Text(ShellCopy.name(of: store.scope))
                        .font(Font.Token.title)
                        .tracking(Font.Token.titleTracking)
                        .foregroundStyle(Color.textPrimary)
                    HStack(spacing: Spacing.s) {
                        Text(AppStore.subtitle(of: store.scope.root))
                            .font(Font.Token.mono)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if showsReveal(state) {
                            Button(OverviewCopy.revealInFinder) { Workspace.reveal(store.scope.root) }
                                .buttonStyle(.plain)
                                .font(Font.Token.calloutMedium)
                                .foregroundStyle(Color.accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let targets = store.snapshot?.targets, isSetUp {
                    HStack(spacing: Spacing.inline) {
                        ForEach(targets.entries, id: \.self) { target in
                            Pill(ShellCopy.agentName(target), style: .agent)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(OverviewCopy.agentsLabel)
                }
            }
            strip(state.strip())
            if let partial = store.partialFailure, isSetUp {
                PartialRefreshStrip(partial, showsDetails: showsPartialDetails)
            }
        }
        .padding(.top, Self.headerTopPadding)
        .padding(.horizontal, Size.columnPadding)
        .padding(.bottom, Self.headerBottomPadding)
        .background(Color.surfaceWindow)
    }

    /// The counts, then `Checked 4 min ago  Check Now` at the trailing end; the counts over the checked line when
    /// the column is narrow (the board's `flex-wrap: wrap`). Loading: spinner, words and a skeleton bar.
    @ViewBuilder private func strip(_ strip: OverviewStrip) -> some View {
        Group {
            if strip.isLoading {
                HStack(spacing: Spacing.cardGap) {
                    Spinner(label: strip.segments.first?.words)
                    SkeletonBar(width: Self.loadingBarWidth)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Self.stripGap) {
                        counts(strip)
                        Spacer(minLength: Spacing.s)
                        checked(strip)
                    }
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack(spacing: Self.stripGap) { counts(strip) }
                        checked(strip)
                    }
                }
            }
        }
        .font(Font.Token.callout)
        .foregroundStyle(Color.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(strip.sentence)
    }

    @ViewBuilder private func counts(_ strip: OverviewStrip) -> some View {
        ForEach(strip.segments, id: \.self) { segment in
            HStack(spacing: Self.stripDotGap) {
                switch segment.dot {
                case .severity(let severity): StatusDot(severity)
                case .notSetUp: StatusDot.notSetUp
                case nil: EmptyView()
                }
                segmentText(segment).fixedSize()
            }
        }
    }

    /// `<strong>3</strong> need sync`: the number in primary semibold.
    private func segmentText(_ segment: OverviewStrip.Segment) -> Text {
        guard let number = segment.number else { return Text(segment.words) }
        return Text("\(number)").font(Font.Token.calloutSemibold).foregroundStyle(Color.textPrimary)
            + Text(" " + segment.words)
    }

    @ViewBuilder private func checked(_ strip: OverviewStrip) -> some View {
        if let checked = strip.checked {
            HStack(spacing: Spacing.s) {
                Text(checked).fixedSize()
                if strip.showsCheckNow {
                    Button(OverviewCopy.checkNow) { Task { await store.checkUpdates() } }
                        .buttonStyle(.plain)
                        .font(Font.Token.calloutSemibold)
                        .foregroundStyle(Color.accent)
                        .fixedSize()
                        .disabled(store.isRefreshing || store.isCheckingUpdates)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder private func content(_ state: OverviewState, columns: [GridItem]) -> some View {
        switch state {
        case .loading:
            OverviewSkeleton(columns: columns)
        case .failed(let error):
            FailureBanner(ErrorCopy.message(for: error), onRetry: { Task { await store.refresh() } })
        case .notSetUp:
            EmptyState(
                icon: "folder.badge.questionmark", title: EmptyCopy.notSetUpTitle,
                body: EmptyCopy.notSetUpBody(agents: []),
                actions: [
                    .primary(EmptyCopy.setUp) { Task { await app.setUp(store, runner: runner) } },
                    .secondary(EmptyCopy.removeFromSidebar) { app.removeFromSidebar(store.scope) },
                ],
                style: .dashed, textWidth: EmptyState.notSetUpTextWidth)
        case .noProjects(let snapshot):
            noProjects(snapshot)
        case .ready(let snapshot):
            cardRows(snapshot, columns: columns.count)
        }
    }

    /// Overview-States "No projects yet": the not-managed banner, then the add-a-project hint block.
    private func noProjects(_ snapshot: ScopeSnapshot) -> some View {
        let notManaged = snapshot.entries.filter(\.isNotManaged).count
        return VStack(spacing: Self.gridGap) {
            if notManaged > 0 {
                MessageStrip(
                    .warning, title: StripCopy.notManagedTitle(count: notManaged),
                    text: StripCopy.notManagedBody(count: notManaged),
                    trailing: .button(StripCopy.review) { Self.reviewNotManaged(in: store) })
            }
            EmptyState(
                icon: "folder.badge.plus", title: EmptyCopy.noProjectsTitle, body: EmptyCopy.noProjectsBody,
                actions: [
                    .primary(EmptyCopy.openFolder, shortcutHint: EmptyCopy.openFolderShortcut, perform: openFolder),
                    .secondary(EmptyCopy.findProjects, perform: findProjects),
                ],
                style: .dashed, textWidth: EmptyState.noProjectsTextWidth)
        }
    }

    /// The six cards in rows that measure their height: each row is an `HStack(alignment: .top)` fixed to its
    /// ideal height, so the cards of a row stretch to the taller one and a wrapping cell never makes a row draw
    /// taller than it was measured (a `LazyVGrid` row overlapped the next one).
    @ViewBuilder private func cardRows(_ snapshot: ScopeSnapshot, columns: Int) -> some View {
        let quiet = Self.isQuiet(snapshot)
        if columns >= 2 {
            VStack(alignment: .leading, spacing: Self.gridGap) {
                row {
                    health(snapshot)
                    updates(snapshot)
                }
                row {
                    security(snapshot)
                    SourcesCard(snapshot: snapshot, isCompact: quiet)
                }
                row {
                    PolicyCard(snapshot: snapshot, isCompact: quiet)
                    AgentsCard(snapshot: snapshot, agents: store.agentIndex, isCompact: quiet)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Self.gridGap) {
                row { health(snapshot) }
                row { updates(snapshot) }
                row { security(snapshot) }
                row { SourcesCard(snapshot: snapshot, isCompact: quiet) }
                row { PolicyCard(snapshot: snapshot, isCompact: quiet) }
                row { AgentsCard(snapshot: snapshot, agents: store.agentIndex, isCompact: quiet) }
            }
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Self.gridGap) {
            // A modifier on a Group applies to each card: equal shares, as the board's two equal columns.
            Group { content() }
                .frame(minWidth: 0, maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func health(_ snapshot: ScopeSnapshot) -> some View {
        HealthCard(
            snapshot: snapshot, isBusy: runner.isRunning, onRepair: { runner.start(.repair, in: store) },
            onSync: { runner.start(.sync, in: store) }, onCheckAgain: { runner.start(.check, in: store) },
            onTitleTap: { show(Self.filter(for: .health)) })
    }

    private func updates(_ snapshot: ScopeSnapshot) -> some View {
        UpdatesCard(
            snapshot: snapshot, onTitleTap: { show(Self.filter(for: .updates)) },
            onReviewAll: { app.request(.updateAll) }, onReview: { app.request(.update(package: $0)) })
    }

    private func security(_ snapshot: ScopeSnapshot) -> some View {
        SecurityCard(snapshot: snapshot, onTitleTap: { show(Self.filter(for: .security)) })
    }

    // MARK: - Actions

    /// The cards whose title opens the filtered list.
    enum LinkedCard: CaseIterable {
        case health
        case updates
        case security
    }

    /// "Every card title links to the filtered list (Needs attention / Updates)."
    static func filter(for card: LinkedCard) -> Filter {
        switch card {
        case .health, .security: .needsAttention
        case .updates: .updates
        }
    }

    private func show(_ filter: Filter) {
        Self.show(filter, in: store)
    }

    /// A card title: the list shows `filter` and no row stays selected.
    static func show(_ filter: Filter, in store: ScopeStore) {
        store.clearSelection()
        store.filter = filter
    }

    /// The not-managed banner's Review (Flow-F1 step 3): the Not managed chip, and its first row selected (the
    /// detail loads it through its `.task(id: selection)`). A search query that hides every not-managed row is
    /// cleared first, so Review never lands on an empty list.
    static func reviewNotManaged(in store: ScopeStore) {
        store.filter = .notManaged
        if store.visibleEntries.isEmpty {
            store.query = ""
        }
        store.selection = store.visibleEntries.first?.id
    }

    private func openFolder() {
        if let folder = Workspace.chooseFolder(prompt: EmptyCopy.openFolder) {
            app.open(folder: folder)
        }
    }

    private func findProjects() {
        if let folder = Workspace.chooseFolder(prompt: EmptyCopy.findProjects) {
            app.request(.findProjects(root: folder))
        }
    }
}
