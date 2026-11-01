import SkillcaskDomain
import SwiftUI

extension PreviewRegistry {
    /// The Main board's list (the api scope's 14 rows, worst first, pdf selected) in a real `List` so the
    /// system draws the selection; the same list offline and stale; and the Components region: one row per
    /// trailing variant plus the project, dependency and not managed rows on the window surface. `cli` comes first:
    /// the same list over `DesignFixtures.apiCLI`, the api scope as the 0.9.4 CLI prints it (no descriptions, no
    /// not managed row); the others draw api's planned shape.
    static let rows: [Entry] = [
        Entry(id: "P2-5", state: "cli", size: rowsListSize) { AnyView(RowsList(snapshot: DesignFixtures.apiCLI)) },
        Entry(id: "P2-5", state: "rows", size: rowsListSize) { AnyView(RowsList()) },
        Entry(id: "P2-5", state: "offline", size: rowsListSize) { AnyView(RowsList(isOffline: true)) },
        Entry(id: "P2-5", state: "stale", size: rowsListSize) { AnyView(RowsList(isStale: true)) },
        Entry(id: "P2-5", state: "variants", size: rowVariantsSize) { AnyView(RowVariants()) },
        Entry(id: "P2-5", state: "agents", size: agentsListSize(Size.listWidth)) {
            AnyView(RowsList(snapshot: DesignFixtures.agents, selected: DesignFixtures.agentsReviewNotes.id))
        },
        Entry(id: "P2-5", state: "agentsNarrow", size: agentsListSize(Size.listMinWidth)) {
            AnyView(RowsList(snapshot: DesignFixtures.agents, selected: DesignFixtures.agentsReviewNotes.id))
        },
        Entry(id: "P2-5", state: "agentsSingleTarget", size: rowsSize(DesignFixtures.websiteLinkMissing)) {
            AnyView(RowsList(snapshot: DesignFixtures.websiteLinkMissing, selected: nil))
        },
    ]
}

/// The list column at its board width, tall enough for every api row plus the list's own margins.
private let rowsListSize = CGSize(
    width: Size.listWidth, height: CGFloat(DesignFixtures.api.entries.count) * Size.row + 2 * Spacing.l)
/// The agent-badge lists (`DesignFixtures.agents`, `websiteLinkMissing`): every row of the scope at `width`.
private func agentsListSize(_ width: CGFloat) -> CGSize {
    CGSize(width: width, height: CGFloat(DesignFixtures.agents.entries.count) * Size.row + 2 * Spacing.l)
}

private func rowsSize(_ snapshot: ScopeSnapshot) -> CGSize {
    CGSize(width: Size.listWidth, height: CGFloat(snapshot.entries.count) * Size.row + 2 * Spacing.l)
}

private let rowVariantsSize = CGSize(width: Size.listWidth + 2 * Spacing.l, height: 11 * Size.row + 2 * Spacing.l)

/// `Filter.all` over the api scope in a `List(selection:)` with pdf selected: the rows as the list screen will
/// host them. For the skills list: `.inset` adds its own side margins to every row (the board's 6 pt) and draws
/// hairline separators the board lacks (`.listRowSeparator(.hidden)`); `.listRowInsets(EdgeInsets())` leaves the
/// row's own 14/12 padding as the only inset. Stale is the whole list at `SkillRow.staleOpacity`, selection
/// included, as List-States fades it. The render tool's window is borderless and never key, so the system draws
/// its selection in the inactive grey there; the preview therefore also tells the selected row it is selected and
/// lays the accent under it, which is what the system draws in an active window. The list screen needs neither:
/// `List(selection:)` alone raises `backgroundProminence` on the selected row.
private struct RowsList: View {
    let snapshot: ScopeSnapshot
    let isOffline: Bool
    let isStale: Bool
    @State private var selection: SkillEntry.ID?
    private let agents: AgentIndex

    init(
        snapshot: ScopeSnapshot = DesignFixtures.api, isOffline: Bool = false, isStale: Bool = false,
        selected: SkillEntry.ID? = DesignFixtures.pdf.id
    ) {
        self.snapshot = snapshot
        self.isOffline = isOffline
        self.isStale = isStale
        agents = DesignFixtures.agentIndex(snapshot)
        _selection = State(initialValue: selected)
    }

    var body: some View {
        List(Filter.all.apply(snapshot.entries), selection: $selection) { entry in
            let isSelected = entry.id == selection
            SkillRow(
                entry, isSelected: isSelected, isOffline: isOffline,
                requiredBy: snapshot.requirerSkills(of: entry), agents: agents.reach(of: entry)
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(
                isSelected
                    ? RoundedRectangle(cornerRadius: Radius.m).fill(Color.accentColor)
                        .padding(.horizontal, Spacing.inline)
                    : nil)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Color.surfaceWindow)
        .opacity(isStale ? SkillRow.staleOpacity : 1)
    }
}

/// The Components board's "Skill row" region: installed, update, changed on disk, not installed, not managed,
/// project skill (quiet), project with findings, dependency, cooldown, blocked by policy, then the selected row
/// on the system accent. The rows come from `DesignFixtures.api`, a planned shape: their descriptions are the
/// unshipped `status.description` key, and the not managed caveman row sits in a project scope, which 0.9.4 never
/// reports.
private struct RowVariants: View {
    /// my-notes with a clean audit: the board's quiet "Project skill" row (ok dot, `.skills/my-notes` · Project).
    static let projectSkill = SkillEntry(
        id: DesignFixtures.myNotes.id, name: DesignFixtures.myNotes.name, kind: .project, source: nil,
        version: nil, state: .project, health: .projectSkill, update: nil, findings: [],
        path: DesignFixtures.myNotes.path, description: DesignFixtures.myNotes.description)

    var body: some View {
        VStack(spacing: 0) {
            SkillRow(DesignFixtures.commitMessage)
            SkillRow(DesignFixtures.pdf)
            SkillRow(DesignFixtures.deployChecklist)
            SkillRow(DesignFixtures.sqlReview)
            SkillRow(DesignFixtures.caveman)
            SkillRow(Self.projectSkill)
            SkillRow(DesignFixtures.myNotes)
            SkillRow(
                DesignFixtures.safeRefactor,
                requiredBy: DesignFixtures.api.requirerSkills(of: DesignFixtures.safeRefactor))
            SkillRow(DesignFixtures.jiraCommunication)
            SkillRow(DesignFixtures.testWriter)
            SkillRow(DesignFixtures.pdf, isSelected: true)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.m))
        }
        .frame(width: Size.listWidth)
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surfaceWindow)
    }
}
