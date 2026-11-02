import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// One row of the skills list: a `SkillRow` told whether it is selected, with the board's hover (Components board
/// "hover with actions"): `surfaceHover` behind an unselected row, and the trailing slot swapped for Update… and
/// the ⋯ menu (`SkillRowActions`). Update…, Remove… and Adopt… set `AppStore.sheet`, which `MainWindow`
/// presents; Reveal in Finder selects the row's folder.
struct SkillListRow: View {
    let entry: SkillEntry
    let scope: Scope
    let isSelected: Bool
    let isOffline: Bool
    let requiredBy: [String]
    /// The agent badges (`ScopeStore.agentReach(for:)`).
    let agents: AgentReach
    /// False while a window run is in flight in this scope: every mutation waits for it, so the hover offers none.
    let showsActions: Bool

    @Environment(AppStore.self) private var app
    @State private var isHovering: Bool

    /// - Parameter hovering: Previews only: draws the row as hovered (a render has no pointer).
    init(
        entry: SkillEntry, scope: Scope, isSelected: Bool, isOffline: Bool, requiredBy: [String],
        agents: AgentReach = .none, hovering: Bool = false, showsActions: Bool = true
    ) {
        self.entry = entry
        self.scope = scope
        self.isSelected = isSelected
        self.isOffline = isOffline
        self.requiredBy = requiredBy
        self.agents = agents
        self.showsActions = showsActions
        _isHovering = State(initialValue: hovering)
    }

    /// Where `.inset` draws the system selection from the list's edges (measured in the renders: 10 pt), so the
    /// hover fill lines up with the accent highlight.
    static let highlightInset = Spacing.rowGap

    var body: some View {
        SkillRow(
            entry, isSelected: isSelected, isOffline: isOffline, requiredBy: requiredBy,
            accessory: isHovering && showsActions ? AnyView(controls) : nil, agents: agents
        )
        .contentShape(Rectangle())
        .listRowBackground(
            isHovering && !isSelected
                ? RoundedRectangle(cornerRadius: Radius.m).fill(Color.surfaceHover)
                    .padding(.horizontal, Self.highlightInset) : nil
        )
        .onHover { isHovering = $0 }
    }

    // MARK: - Derived

    private var actions: SkillRowActions {
        .resolve(entry, offline: isOffline)
    }

    // MARK: - Subviews

    /// `display: inline-flex; gap: 4px`: two small bordered controls.
    private var controls: some View {
        HStack(spacing: Spacing.xs) {
            if actions.updatePackage != nil {
                Button(ListCopy.update) { app.request(.update(for: entry)) }
            }
            if !actions.menu.isEmpty {
                Menu {
                    menuItems
                } label: {
                    Label(ListCopy.more, systemImage: "ellipsis").labelStyle(.iconOnly)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help(ListCopy.more)
                .accessibilityLabel(ListCopy.more)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder private var menuItems: some View {
        ForEach(actions.menu, id: \.self) { item in
            Button(ListCopy.title(item)) { perform(item) }
        }
    }

    private func perform(_ item: SkillRowActions.MenuItem) {
        switch item {
        case .remove: app.request(.remove(skills: [entry.id]))
        case .adopt: app.request(.adopt(skills: [entry.id]))
        case .revealInFinder:
            if let path = entry.path {
                Workspace.reveal(scope.root.appending(path: path))
            }
        }
    }
}
