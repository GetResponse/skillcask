import AppKit
import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The one window (Main and Overview boards, Rationale): a `NavigationSplitView` of sidebar, skills list and
/// detail, the unified toolbar, the scope's name and path as the window title. Column widths are the Tokens
/// board's (sidebar 220 / min 180, list 360 / min 300, detail min 400). Those ideals sum to 980 and the detail's
/// 400 is fixed, so at the 960 pt minimum the list gives first (360 → 340) and the sidebar stays at 220; the
/// user can narrow either to its minimum (`macos/DESIGN.md` G9; this is what `NavigationSplitView`
/// does with these values). A project without skills.toml shows the Set Up block in the detail and an empty
/// list. The stores come from the environment (`skillcaskEnvironment`); the scene boots the app on appear. It always
/// opens with the three columns shown (`SplitViewFrames`).
public struct MainWindow: View {
    /// The window's minimum height; the boards are 800 tall, 600 keeps the Overview grid readable.
    public static let minHeight: CGFloat = 600
    /// The scene's id, so Settings and the app menu can open the window when none is open; SwiftUI starts its
    /// windows' identifiers with it (`Workspace.isMainScene`).
    public nonisolated static let sceneID = "main"

    @Environment(AppStore.self) private var app
    @Environment(ActionRunner.self) private var runner
    @Environment(AppUpdateStore.self) private var updates
    @State private var columns = NavigationSplitViewVisibility.all
    /// The Remove alert built once per request (its plan is computed when asked for, not on every render).
    @State private var pinnedRemoval: (id: UUID, alert: RemoveAlert)?

    public init() {}

    public var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: Size.sidebarMinWidth, ideal: Size.sidebarWidth)
        } content: {
            content
                .navigationSplitViewColumnWidth(min: Size.listMinWidth, ideal: Size.listWidth)
        } detail: {
            detail
                .frame(minWidth: Size.detailMinWidth)
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { ScopeToolbar(app: app, runner: runner, store: app.selectedStore) }
        .focusedSceneValue(\.appStore, app)
        .focusedSceneValue(\.scopeStore, app.selectedStore)
        .focusedSceneValue(\.actionRunner, runner)
        .frame(minWidth: Size.windowMinWidth, minHeight: Self.minHeight)
        .sheet(item: presentedSheet) { presentation in
            if let store = app.store(for: presentation.scope) {
                SheetHost(sheet: presentation.sheet, store: store) { app.dismiss(presentation) }
            } else {
                // The pinned scope has no store (the CLI went away): close rather than show an empty sheet.
                Color.surfaceWindow.task { app.dropOrphanedPresentation() }
            }
        }
        .alert(
            removeAlert?.title ?? "", isPresented: removalShown, presenting: removeAlert,
            actions: { alert in alert.actions(onRemove: { alert.confirm(runner: runner) }) },
            message: { alert in alert.message }
        )
        .onChange(of: app.presentation) {
            app.dropOrphanedPresentation()
            pinnedRemoval = removeAlert.flatMap { alert in app.removal.map { ($0.id, alert) } }
        }
        .onChange(of: app.cli) { app.dropOrphanedPresentation() }
        .onChange(of: app.scopes) { app.dropOrphanedPresentation() }
        .background { onboarding }
        .modifier(AppUpdateHost(app: app, updates: updates))
        .modifier(LiveRefreshHost(app: app))
        .task { await app.boot() }
    }

    // MARK: - Onboarding (S13)

    /// The onboarding sheet over the empty window while the CLI is missing or too old (`AppStore.isOnboarding`).
    /// Hosted on a background view so it never shares a presenter with `presentedSheet`; it cannot be closed
    /// from here, only by a detection that succeeds.
    private var onboarding: some View {
        Color.clear
            .sheet(isPresented: Binding(get: { app.isOnboarding }, set: { _ in })) {
                CLIOnboardingSheet(state: OnboardingState.resolve(app.cli, binary: app.binary) ?? .missing)
            }
    }

    // MARK: - Sheets (`AppStore.Sheet`)

    /// The sheet on screen, pinned to the scope it was asked for; SwiftUI's own close (Esc when allowed) clears
    /// that presentation only.
    private var presentedSheet: Binding<AppStore.Presentation?> {
        Binding(
            get: { app.presentedSheet },
            set: { if $0 == nil, let shown = app.presentedSheet { app.dismiss(shown) } })
    }

    /// The S10 alert of a Remove request, over the scope it was asked for.
    private var removeAlert: RemoveAlert? {
        guard let removal = app.removal, case .remove(let skills) = removal.sheet,
            let store = app.store(for: removal.scope)
        else { return nil }
        if let pinnedRemoval, pinnedRemoval.id == removal.id {
            return pinnedRemoval.alert
        }
        return RemoveAlert(skills: skills, store: store)
    }

    /// Shown while a Remove request with a store is pending (an orphaned one is dropped); any button or Esc
    /// clears it.
    private var removalShown: Binding<Bool> {
        Binding(get: { removeAlert != nil }, set: { if !$0, let shown = app.removal { app.dismiss(shown) } })
    }

    // MARK: - Derived

    private var title: String {
        app.selectedScope.map(ShellCopy.name(of:)) ?? ""
    }

    private var subtitle: String {
        guard let scope = app.selectedScope, let item = app.item(for: scope) else { return "" }
        return item.subtitle ?? ""
    }

    // MARK: - Columns

    /// The skills list, or the empty column, with the Activity drawer (S15) at its bottom when shown.
    private var content: some View {
        ActivityPane {
            if let store = app.selectedStore, isSetUp {
                SkillListView(store: store)
            } else {
                Color.surfaceWindow
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let store = app.selectedStore {
            if isSetUp {
                SkillDetailView(store: store)
            } else {
                notSetUp(store)
            }
        } else {
            unavailable
        }
    }

    /// The selected scope has (or is assumed to have) a skills.toml.
    private var isSetUp: Bool {
        app.selectedScope.flatMap { app.item(for: $0)?.isSetUp } ?? true
    }

    /// Overview-States "Folder without skills.toml": the Scope Overview's Set Up block under the scope's header.
    /// The agents Set Up would link are not known before `init` runs, so the body names none.
    private func notSetUp(_ store: ScopeStore) -> some View {
        ScopeOverviewView(store: store, isSetUp: false)
    }

    /// The detail before the CLI is ready: empty, while the first detection runs (Flow-F1 step 0 "Window opens,
    /// columns empty"; nothing is shown before the CLI answers) and under the onboarding sheet (S13) when it failed.
    private var unavailable: some View {
        Color.surfaceWindow
    }
}

// The default preview is the api scope as the 0.9.4 CLI prints it; the dark one keeps the boards' planned shape.
#Preview("MainWindow, light") {
    let stores = Boot.fixtures(api: DesignFixtures.apiCLI)
    MainWindow()
        .skillcaskEnvironment(app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client)
        .frame(width: 1280, height: 800)
}

#Preview("MainWindow, dark") {
    let stores = Boot.fixtures(selecting: Boot.apiScope, selection: nil)
    MainWindow()
        .skillcaskEnvironment(app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client)
        .frame(width: 1280, height: 800)
        .preferredColorScheme(.dark)
}

/// The app-update check's part of the window (D51): the CLI's readiness and the app's activation feed the store,
/// its presentation joins `AppStore.isPresenting`, and the update sheet and the manual check's alert sit on
/// presenters of their own.
private struct AppUpdateHost: ViewModifier {
    let app: AppStore
    let updates: AppUpdateStore

    func body(content: Content) -> some View {
        content
            .background { appUpdateSheet }
            .background { appUpdateAlert }
            .onChange(of: app.isReady, initial: true) { updates.cliChanged(isReady: app.isReady) }
            .onChange(of: updates.isPresenting, initial: true) { app.isAppUpdatePresenting = updates.isPresenting }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await updates.checkIfDue() }
            }
    }

    /// The scope sheets, the Remove alert and the onboarding sheet have the window: the app-update sheet and alert
    /// wait until none is up, so two never stack.
    private var appUpdateMayPresent: Bool {
        app.presentation == nil && !app.isOnboarding
    }

    /// The update sheet (U2/U3) on a presenter of its own; Esc closes it with no state change.
    private var appUpdateSheet: some View {
        Color.clear
            .sheet(
                item: Binding(
                    get: { appUpdateMayPresent ? updates.sheet : nil },
                    set: { if $0 == nil { updates.dismissSheet() } })
            ) { request in
                if let installed = updates.installed {
                    AppUpdateSheet(version: request.version, installed: installed)
                }
            }
    }

    /// The manual check's answer when it is not an update (U4): OK, with Try Again where asking again can help.
    private var appUpdateAlert: some View {
        Color.clear
            .alert(
                updates.alert?.title ?? "",
                isPresented: Binding(
                    get: { appUpdateMayPresent && updates.alert != nil }, set: { if !$0 { updates.alert = nil } }),
                presenting: updates.alert,
                actions: { alert in
                    if alert.offersRetry {
                        Button(AppUpdateCopy.tryAgain) { Task { await updates.retry() } }
                    }
                    Button(AppUpdateCopy.ok, role: .cancel) { updates.alert = nil }
                },
                message: { alert in Text(alert.message) }
            )
    }
}

/// Live refresh's part of the window: the stream follows the selected scope (`LiveRefresh.follow`, again whenever
/// the selection, the CLI, the environment or a snapshot changes), stops with the last window (each window attaches
/// and detaches; a tab's window shares the one `LiveRefresh`). `LiveRefresh` observes the app's activation itself,
/// once for all windows.
private struct LiveRefreshHost: ViewModifier {
    let app: AppStore

    /// What the plan is built from; a new value asks `follow()`, which restarts the stream only if the plan moved.
    private struct Followed: Hashable {
        let scope: Scope?
        /// A store rebuilt over a new CLI is followed anew.
        let store: ObjectIdentifier?
        let isReady: Bool
        let environment: EnvironmentPolicy
        let checkedAt: Date?
        let targets: StatusDocument.Targets?
    }

    private var followed: Followed {
        let store = app.selectedStore
        return Followed(
            scope: app.selectedScope, store: store.map(ObjectIdentifier.init), isReady: app.isReady,
            environment: app.environment, checkedAt: store?.checkedAt, targets: store?.snapshot?.targets)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { app.liveRefresh.attach() }
            .onChange(of: followed) { app.liveRefresh.follow() }
            .onDisappear { app.liveRefresh.detach() }
    }
}
