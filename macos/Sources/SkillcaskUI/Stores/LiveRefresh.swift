import Foundation
import SkillcaskCore

/// Live refresh: shows what a terminal or an agent changed in the selected scope without ⌘R. Watches the selected
/// scope's `WatchPlan` roots only, with its heavy directories excluded and its relevance filter applied off the main
/// actor; after `debounce` without another relevant change (or rescan) it runs one silent
/// `ScopeStore.refreshAfterChange()`. A change in a project the sidebar shows as not set up, or whose store found
/// no skills.toml, checks the manifests again too (`AppStore.refreshSetUp`), so `init` in a terminal turns the Set
/// Up block into the list. The CLI's read-only commands write nothing, so a refresh never triggers itself.
///
/// A change only restarts the debounce. A refresh, once started, is never cancelled by a change or by the stream
/// restarting for a new plan (its own snapshot can move the plan; the new stream resumes at the old one's last
/// event), only by following another store or by the last window closing. A change that arrives while any other
/// refresh of the store runs (this one, ⌘R, the first open) marks the scope dirty, and one more refresh follows a
/// debounce after it lands, so a user's refresh is never superseded and keeps its Activity row. A change during a
/// mutation's refresh is the app's own write and is dropped (`ScopeStore.refreshAfterChange`).
@MainActor public final class LiveRefresh {
    /// Quiet time after the last relevant change before the refresh: a `skillcask add` writes many files.
    public static let defaultDebounce: Duration = .milliseconds(700)

    /// Set by `AppStore`, which owns this coordinator.
    weak var app: AppStore?
    private let watcher: any FileWatching
    private let debounce: Duration
    private let home: URL
    /// The store and plan the stream follows; nil while nothing is watched.
    private var followed: (store: ScopeStore, plan: WatchPlan)?
    /// The debounce sleep before a refresh; restarted by every change.
    private var waiting: Task<Void, Never>?
    /// The refresh in flight; never cancelled by a change.
    private var running: Task<Void, Never>?
    /// A change arrived while a refresh ran: one more follows when it lands.
    private var isDirty = false
    /// Windows hosting live refresh (`attach`/`detach`): the stream stops with the last.
    private var hosts = 0
    /// An activation refresh is being asked for: every window observes activation, one asks.
    private var isActivating = false

    public init(
        watcher: any FileWatching, debounce: Duration = LiveRefresh.defaultDebounce,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.watcher = watcher
        self.debounce = debounce
        self.home = home
    }

    /// A window that shows the selected scope appeared: follow it.
    public func attach() {
        hosts += 1
        follow()
    }

    /// A window went away; the last one stops everything.
    public func detach() {
        hosts = max(0, hosts - 1)
        if hosts == 0 {
            stop()
        }
    }

    /// Follows the selected scope: builds its plan from the config directory and the last `status`'s target
    /// directories and restarts the stream only when the plan changed. A different store drops the old one's
    /// waiting and running refresh; the same store keeps them.
    public func follow() {
        guard let app, let store = app.selectedStore else {
            stop()
            return
        }
        let plan = WatchPlan(
            scope: store.scope, configDirectory: app.configDirectory(),
            targetDirs: store.snapshot?.targets?.dirs ?? [], home: home)
        let resuming = followed?.store === store
        if let followed, resuming {
            guard followed.plan != plan else { return }
            self.followed = (store, plan)
        } else {
            stop()
            followed = (store, plan)
            store.onRefreshEnded = { [weak self, weak store] in
                guard let self, let store else { return }
                self.refreshEnded(in: store)
            }
        }
        watcher.start(
            roots: plan.roots, excluding: plan.exclusions, resuming: resuming, isRelevant: plan.isRelevant
        ) { [weak self] in self?.schedule() }
    }

    /// Ends the stream and drops the waiting and running refresh.
    public func stop() {
        watcher.stop()
        waiting?.cancel()
        waiting = nil
        running?.cancel()
        running = nil
        isDirty = false
        followed?.store.onRefreshEnded = nil
        followed = nil
    }

    /// The app became active: the selected scope refreshes if stale, silently (`ScopeStore.refreshOnActivate`).
    public func activated() async {
        guard !isActivating, let app, let scope = app.selectedScope, app.isSetUp(scope),
            let store = app.selectedStore
        else { return }
        isActivating = true
        defer { isActivating = false }
        await store.refreshOnActivate()
    }

    /// Tests: returns once no refresh waits or runs.
    func settled() async {
        while true {
            if let waiting {
                await waiting.value
            } else if let running {
                await running.value
            } else {
                return
            }
        }
    }

    /// (Re)starts the debounce.
    private func schedule() {
        waiting?.cancel()
        let debounce = debounce
        waiting = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.waiting = nil
            self.fire()
        }
    }

    /// The debounce ran out: refresh now, or after the refresh in flight lands.
    private func fire() {
        guard let app, let store = followed?.store, app.selectedStore === store,
            !store.isRefreshingAfterMutation
        else { return }
        if running != nil || store.isReading {
            isDirty = true
            return
        }
        isDirty = false
        let checkSetUp = !store.scope.isPersonal && (!app.isSetUp(store.scope) || store.presentation == .noManifest)
        running = Task { [weak self, weak app] in
            await store.refreshAfterChange()
            if checkSetUp {
                await app?.refreshSetUp()
            }
            guard !Task.isCancelled, let self else { return }
            self.running = nil
            self.followUp()
        }
    }

    /// A refresh of the followed store ended (any trigger).
    private func refreshEnded(in store: ScopeStore) {
        guard followed?.store === store, running == nil else { return }
        followUp()
    }

    /// One more refresh for the changes held back, after a debounce.
    private func followUp() {
        if isDirty, waiting == nil {
            isDirty = false
            schedule()
        }
    }
}
