import SkillcaskCore
import SwiftUI

/// The sidebar (Main board): a `List` of scopes in two sections, Personal with the one "My Skills" row and
/// Projects with the recent project folders, each a `ScopeRow` with its `ScopeBadge`. Selection is the system's
/// (bound to `AppStore.selectedScope`). With no projects, the Onboarding-States hint (`SidebarHint`) sits under the
/// Projects header; the bottom line repeats Open Folder… with its shortcut, which the File menu binds.
///
/// A badge is the scope store's attention once the scope was opened, else its background `status` summary
/// (`AppStore.attention(for:)`). A folder dropped on the sidebar is added and selected as Open Folder… would
/// (`AppStore.open(dropped:)`). Until the CLI answers (Flow-F1 step 0) the rows are dimmed and cannot be selected.
struct SidebarView: View {
    @Environment(AppStore.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedScope) {
            Section(ShellCopy.personal) {
                ScopeRow(item: personal, attention: app.attention(for: .personal))
                    .tag(Scope.personal)
                    .modifier(Locating(isLocating: !app.isReady))
            }
            Section(ShellCopy.projects) {
                if SidebarHint.isShown(projects: app.projects) {
                    hint
                } else {
                    ForEach(app.projects) { item in
                        ScopeRow(item: item, attention: app.attention(for: item.scope))
                            .tag(item.scope)
                            .modifier(Locating(isLocating: !app.isReady))
                            .contextMenu {
                                Button(ShellCopy.removeFromSidebar) { app.removeFromSidebar(item.scope) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel(ShellCopy.scopesLabel)
        // The inset is outside the `List`: the split view was observed (macOS 26 and 27) to take the sidebar's minimum
        // height from it measured at zero width, where any vertically fixed text wraps a letter per line and pushes
        // the columns out of the window (`SidebarCardLayoutTests`). At the column's own minimum width it cannot.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer.frame(minWidth: Size.sidebarMinWidth) }
        .dropDestination(for: URL.self) { urls, _ in app.open(dropped: urls) != nil }
    }

    // MARK: - Derived

    private var personal: AppStore.ScopeItem {
        app.item(for: .personal) ?? AppStore.ScopeItem(scope: .personal, name: ShellCopy.personalScope, subtitle: nil)
    }

    // MARK: - Subviews

    /// Onboarding-States "First launch": the dashed hint with Open Folder… and Find Projects in Folder….
    private var hint: some View {
        SidebarHint(onOpenFolder: openFolder, onFindProjects: findProjects)
            .modifier(Unready(isUnready: !app.isReady))
            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: 0, bottom: Spacing.xs, trailing: 0))
    }

    /// The board's bottom line: a plus glyph and "Open Folder… ⌘O" in secondary 11 pt, over a hairline.
    /// U1's app-update card sits above it, inside the sidebar's padding (`AppUpdateCardSlot`).
    private var footer: some View {
        VStack(spacing: 0) {
            AppUpdateCardSlot()
            Rectangle()
                .fill(Color.separator)
                .frame(height: Size.hairline)
            Button(action: openFolder) {
                HStack(spacing: Spacing.inline) {
                    Image(systemName: "plus")
                        .font(Font.Token.callout)
                    Text(ShellCopy.openFolder + " " + ShellCopy.openFolderShortcutHint)
                        .font(Font.Token.caption)
                }
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ShellCopy.addProject)
            .modifier(Unready(isUnready: !app.isReady))
        }
    }

    private func findProjects() {
        if let folder = Workspace.chooseFolder(prompt: EmptyCopy.findProjects) {
            app.request(.findProjects(root: folder))
        }
    }

    private func openFolder() {
        if let folder = Workspace.chooseFolder(prompt: EmptyCopy.openFolder) {
            app.open(folder: folder)
        }
    }
}

/// Flow-F1 step 0: Open Folder… and Find Projects in Folder… (hint and footer) are disabled and dimmed until the
/// CLI is ready, as the File menu items are.
private struct Unready: ViewModifier {
    let isUnready: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isUnready)
            .opacity(isUnready ? SkillRow.staleOpacity : 1)
    }
}

/// Flow-F1 step 0: while the CLI is located the rows are dimmed (`SkillRow.staleOpacity`) and not selectable.
private struct Locating: ViewModifier {
    let isLocating: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isLocating ? SkillRow.staleOpacity : 1)
            .selectionDisabled(isLocating)
    }
}
