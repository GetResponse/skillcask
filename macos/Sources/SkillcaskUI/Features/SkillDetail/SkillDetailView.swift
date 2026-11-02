import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The detail column: the `DetailHeader` with its tabs for the selected row, or the `ScopeOverviewView` when
/// nothing is selected (S1). The Overview tab is `OverviewTab` over `OverviewContent`, Security is `SecurityTab` over
/// `SecurityContent`, and every other tab is its own view or a placeholder until its task lands. Selection loads
/// through `.task(id:)` on the store's selection. Esc (`onExitCommand`) and a click on empty detail space
/// clear the selection, so the Scope Overview shows again. A tab the row hides (Versions of a project skill) falls
/// back to Overview.
struct SkillDetailView: View {
    let store: ScopeStore

    @Environment(AppStore.self) private var app
    @Environment(ActionRunner.self) private var runner
    @State private var tab = DetailTab.overview
    /// The SKILL.md line the Contents tab scrolls to: set with the switch to Contents by the Security tab's "Show in
    /// file", cleared when the selection changes. Nil when nothing asked for a line.
    @State private var contentsTarget: Int?

    var body: some View {
        Group {
            if let entry = store.selectedEntry {
                VStack(spacing: 0) {
                    DetailHeader(
                        entry: entry, isOffline: store.isOffline, selectedTab: tabBinding(for: entry),
                        requiredBy: store.requirerSkills(for: entry),
                        allowedRange: store.detail?.info.flatMap { DetailOverviewCopy.allowedRange(why: $0.why) },
                        onUpdate: { request(.update(for: entry)) },
                        onAdopt: { request(.adopt(skills: [entry.id])) },
                        onRemove: { request(.remove(skills: [entry.id])) },
                        onReviewChanges: { request(.update(for: entry)) })
                    tabBody(for: entry)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .background(Color.surfaceWindow)
                .onExitCommand { store.clearSelection() }
            } else {
                ScopeOverviewView(store: store)
            }
        }
        .task(id: store.selection) { await store.loadDetail() }
        .onChange(of: store.selection) { contentsTarget = nil }
    }

    // MARK: - Derived

    /// The selected tab as the header sees it: the stored tab when the row has it, else Overview.
    private func tabBinding(for entry: SkillEntry) -> Binding<DetailTab> {
        let tabs = DetailTabs.tabs(for: entry)
        return Binding(
            get: { DetailTabs.resolve(tab, in: tabs) },
            set: { tab = $0 })
    }

    // MARK: - Subviews

    @ViewBuilder private func tabBody(for entry: SkillEntry) -> some View {
        switch DetailTabs.resolve(tab, in: DetailTabs.tabs(for: entry)) {
        case .overview:
            OverviewTab(
                content: OverviewContent(
                    entry: entry, detail: store.detail, snapshot: store.snapshot, scope: store.scope,
                    isOffline: store.isOffline, agents: store.agentReach(for: entry)),
                checkedAt: store.snapshot?.checkedAt,
                onShowSkill: { store.selection = $0 },
                onAddReplacement: { request(.addSkill(query: nil)) },
                canAddReplacement: ToolbarRules.canAddSkill(store.snapshot, isBusy: runner.isRunning),
                onRetry: { Task { await store.loadDetail() } },
                onSeeSecurity: { tab = .security },
                onSeeHealth: { store.clearSelection() },
                onEmptyClick: { store.clearSelection() })
        case .contents:
            ContentsTab(
                entry: entry, detail: store.detail, isLoading: store.isLoadingDetail, root: store.scope.root,
                onSeeSecurity: { tab = .security },
                onCheck: { Task { await store.loadDetail() } },
                targetLine: contentsTarget, onTargetShown: { contentsTarget = nil })
        case .security:
            SecurityTab(
                content: SecurityContent(entry: entry, snapshot: store.snapshot), checkedAt: store.snapshot?.checkedAt,
                isBusy: runner.isRunning,
                onShowInFile: { line in
                    let next = SecurityContent.showInFile(line)
                    contentsTarget = next.contentsTarget
                    tab = next.tab
                },
                onReinstall: { runner.start(.restoreFromLock, in: store) },
                onEmptyClick: { store.clearSelection() })
        case .versions:
            VersionsTab(
                entry: entry, store: store, manifest: app.manifest(of: store.scope),
                onReview: { request(.readChanges(of: entry)) },
                onEmptyClick: { store.clearSelection() })
        }
    }

    private func request(_ sheet: AppStore.Sheet) {
        app.request(sheet)
    }
}
