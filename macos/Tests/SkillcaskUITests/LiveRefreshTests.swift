import AppKit
import Foundation
import SkillcaskDomain
import Testing

@testable import SkillcaskCore
@testable import SkillcaskUI

/// A watcher the test drives: `emit` filters what a stream would report through the filter it was started or
/// retargeted with, as `FSEventsWatcher` does off the main actor, and delivers the rest to whoever started it last.
@MainActor final class FakeWatcher: FileWatching {
    /// What is watched; nil while stopped.
    private(set) var roots: [String]?
    private(set) var starts = 0
    private(set) var retargets = 0
    /// Deliveries that reached the main-actor callback.
    private(set) var delivered = 0
    private var accepts: WatchFilter?
    private var onChange: (@MainActor () -> Void)?

    func start(
        roots: [String], excluding: [String], accepts: @escaping WatchFilter,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.roots = roots
        self.accepts = accepts
        self.onChange = onChange
        starts += 1
    }

    func retarget(_ accepts: @escaping WatchFilter) {
        if self.accepts != nil {
            self.accepts = accepts
        }
        retargets += 1
    }

    func stop() {
        roots = nil
        accepts = nil
        onChange = nil
    }

    func emit(_ paths: [String], rescan: Bool = false) {
        guard let accepts, let onChange else { return }
        let flags = paths.map { _ in rescan ? FSEventsWatcher.rescanFlags : 0 }
        if FSEventsWatcher.delivers(paths: paths, flags: flags, accepts: accepts) {
            delivered += 1
            onChange()
        }
    }
}

/// Live refresh through a fake watcher and the `CLIClient` fake: which changes refresh the selected scope, how
/// often, silently, and when the app's own mutation or a switch of scope means they must not.
@Suite @MainActor struct LiveRefreshTests {
    let client = FakeCLIClient()
    let watcher = FakeWatcher()
    let project: URL
    let other: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "live-refresh-\(UUID().uuidString)")
        project = base.appending(path: "app")
        other = base.appending(path: "other")
        for dir in [project.appending(path: ".agents/skills"), other] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var scope: Scope { .project(project) }

    func app(
        queue: MutationQueue = MutationQueue(), notifications: NotificationCenter = NotificationCenter()
    ) -> (AppStore, ActionRunner) {
        let settings = SettingsStore(defaults: MemoryDefaults.make())
        settings.recentProjects = [project, other]
        let app = AppStore(
            settings: settings, queue: queue, client: client, capabilities: Capabilities(version: Capabilities.minimum),
            textReader: { _ in SkillText.parse("") }, manifestExists: { _ in true },
            liveRefresh: LiveRefresh(watcher: watcher, debounce: .zero, notifications: notifications))
        let runner = ActionRunner(queue: queue)
        app.recordActivity = { [weak runner] in runner?.record($0) }
        app.selectedScope = scope
        app.liveRefresh.follow()
        return (app, runner)
    }

    /// `relative` in the project, as FSEvents reports it.
    func reported(_ relative: String, in root: URL? = nil) -> String {
        (WatchPlan.canonical((root ?? project).path) as NSString).appendingPathComponent(relative)
    }

    func scriptTrio(in scope: Scope? = nil) async {
        let scope = scope ?? self.scope
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
    }

    /// `status` with agent target directories and, from a CLI that prints it, the project skills directory.
    static func status(targets: [String], local: String? = nil) -> String {
        let dirs = targets.map { "\"\($0)\"" }.joined(separator: ",")
        let local = local.map { #","local":"\#($0)""# } ?? ""
        return #"{"ok":true,"entries":[{"package":"acme/pdf","skill":"pdf","version":"1.2.0","state":"ok","ok":true}],"#
            + #""policy":{},"repositories":[],"targets":{"entries":[],"dirs":[\#(dirs)],"from":"default"\#(local)}}"#
    }

    func statusRuns() async -> Int {
        await client.commands.filter { $0 == .status }.count
    }

    @Test(.timeLimit(.minutes(1))) func aRelevantChangeRunsOneSilentRefresh() async {
        await scriptTrio()
        let (app, runner) = app()
        #expect(watcher.roots?.contains(WatchPlan.canonical(project.path)) == true)
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1)
        #expect(app.selectedStore?.snapshot?.entries.map(\.name) == ["pdf"])
        #expect(runner.activity.isEmpty)
        #expect(await !client.commands.contains(.outdated))
    }

    @Test(.timeLimit(.minutes(1))) func anIrrelevantChangeRunsNothing() async {
        let (app, _) = app()
        for _ in 0..<50 {
            watcher.emit([reported("src/main.rs"), reported(".git/index"), reported("")])
        }
        #expect(watcher.delivered == 0, "an irrelevant burst never reaches the main actor")
        await app.liveRefresh.settled()
        #expect(await client.commands.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aBurstRunsOneRefresh() async {
        await scriptTrio()
        let (app, _) = app()
        watcher.emit([reported(".agents/skills/pdf/SKILL.md")])
        watcher.emit([reported("skills.toml")])
        watcher.emit([reported("skills.lock"), reported(".agents/skills/pdf")])
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aRescanOfTheProjectRefreshesButOneOfBuildChurnDoesNot() async {
        await scriptTrio()
        let (app, _) = app()
        for churn in [".venv/lib", ".next/cache", "Pods", ".gradle", "coverage"] {
            watcher.emit([reported(churn)], rescan: true)
        }
        #expect(watcher.delivered == 0, "a rescan away from every location is dropped off the main actor")
        watcher.emit([reported("")], rescan: true)
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1)
    }

    @Test(.timeLimit(.minutes(1))) func switchingScopeIgnoresTheOldOne() async {
        let (app, _) = app()
        watcher.emit([reported("skills.lock")])
        app.selectedScope = .project(other)
        app.liveRefresh.follow()
        await app.liveRefresh.settled()
        #expect(watcher.starts == 2 && watcher.roots?.contains(WatchPlan.canonical(other.path)) == true)
        watcher.emit([reported("skills.lock")])
        #expect(watcher.delivered == 1)
        await app.liveRefresh.settled()
        #expect(await client.commands.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func anUnchangedPlanKeepsTheStream() async {
        let (app, _) = app()
        app.liveRefresh.follow()
        app.liveRefresh.follow()
        #expect(watcher.starts == 1)
        app.liveRefresh.stop()
        #expect(watcher.roots == nil)
    }

    @Test(.timeLimit(.minutes(1))) func theStreamStopsOnlyWithTheLastWindow() async {
        let (app, _) = app()
        app.liveRefresh.attach()
        app.liveRefresh.attach()
        app.liveRefresh.detach()
        #expect(watcher.roots != nil, "another window still shows the scope")
        app.liveRefresh.detach()
        #expect(watcher.roots == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aPlanChangeMidRefreshDoesNotCancelIt() async throws {
        await scriptTrio()
        await client.json(.info(.skill("pdf")), in: scope, #"{"skill":"pdf","kind":"package","path":"x","from":"y"}"#)
        let (app, _) = app()
        let store = try #require(app.selectedStore)
        await store.refresh()
        await store.select("pdf")
        let info = Gate()
        await client.json(.status, in: scope, Self.status(targets: [".claude/skills"]))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await client.json(
            .info(.skill("pdf")), in: scope, #"{"skill":"pdf","kind":"package","path":"x","from":"y"}"#, gate: info)
        watcher.emit([reported("skills.lock")])
        await info.arrived()
        // The refresh's own snapshot moved the plan: the window follows it while the detail still loads. The new
        // target lies under the watched project root, so the stream keeps running with the new filter.
        app.liveRefresh.follow()
        #expect(watcher.starts == 1 && watcher.retargets == 1)
        #expect(!store.isLoadingDetail, "a quiet refresh shows no detail spinner")
        await info.open()
        await app.liveRefresh.settled()
        #expect(!store.isLoadingDetail && store.detail?.info != nil)
        #expect(await client.commands.filter { $0 == .doctor(fix: false) }.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aNewRootRestartsTheStream() async throws {
        let shared = other.appending(path: "skills")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        await client.json(.status, in: scope, Self.status(targets: [shared.path]))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let (app, _) = app()
        await app.selectedStore?.refresh()
        app.liveRefresh.follow()
        #expect(watcher.starts == 2 && watcher.retargets == 0)
        #expect(watcher.roots?.contains(WatchPlan.canonical(shared.path)) == true)
    }

    @Test(.timeLimit(.minutes(1))) func theProjectSkillsDirectoryStatusReportsIsWatched() async throws {
        await client.json(.status, in: scope, Self.status(targets: [], local: "docs/skills"))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let (app, _) = app()
        watcher.emit([reported("docs/skills/foo/SKILL.md")])
        #expect(watcher.delivered == 0, "before status reports it, the project skills are `.skills`")
        await app.selectedStore?.refresh()
        app.liveRefresh.follow()
        await scriptTrio()
        watcher.emit([reported(".skills/foo/SKILL.md")])
        watcher.emit([reported("docs/skills/foo/SKILL.md")])
        #expect(watcher.delivered == 1)
        await app.liveRefresh.settled()
    }

    @Test(.timeLimit(.minutes(1))) func changesDuringARunningRefreshGetExactlyOneMore() async {
        let gate = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await scriptTrio()
        let (app, _) = app()
        watcher.emit([reported("skills.lock")])
        await gate.arrived()
        for _ in 0..<3 {
            watcher.emit([reported(".agents/skills/pdf/SKILL.md")])
            await Task.yield()
        }
        await gate.open()
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aChangeDuringRefreshWaitsForItAndKeepsItsActivityRow() async throws {
        let gate = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let (app, runner) = app()
        let store = try #require(app.selectedStore)
        let userRefresh = Task { await store.refresh() }
        await gate.arrived()
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1, "⌘R in flight is not superseded")
        await scriptTrio()
        await gate.open()
        await userRefresh.value
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 2)
        #expect(runner.activity.map(\.headline) == [ActivityCopy.refreshed(ShellCopy.name(of: scope))])
    }

    @Test(.timeLimit(.minutes(1))) func aLiveRefreshIsQuietButCommandRStillFades() async throws {
        let gate = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let (app, _) = app()
        let store = try #require(app.selectedStore)
        watcher.emit([reported("skills.lock")])
        await gate.arrived()
        let quiet = ListState.resolve(store: store, running: nil)
        #expect(!store.isRefreshing && !quiet.isDimmed && quiet.progressTitle == nil)
        await gate.open()
        await app.liveRefresh.settled()
        let user = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: user)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let refresh = Task { await store.refresh() }
        await user.arrived()
        let loud = ListState.resolve(store: store, running: nil)
        #expect(store.isRefreshing && loud.isDimmed && loud.progressTitle == ListCopy.checking)
        await user.open()
        await refresh.value
    }

    @Test(.timeLimit(.minutes(1))) func theSettleWindowCountsFromTheMutationRefreshsEnd() async throws {
        let (app, _) = app()
        let store = try #require(app.selectedStore)
        let start = Date()
        store.now = { start }
        let gate = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let mutationRefresh = Task { await store.refreshAfterMutation() }
        await gate.arrived()
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        // A slow refresh: it ends long after it started.
        store.now = { start.addingTimeInterval(ScopeStore.settleWindow * 5) }
        await gate.open()
        await mutationRefresh.value
        await app.liveRefresh.settled()
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1, "its own writes neither queue a follow-up nor refresh after it ends")
    }

    @Test(.timeLimit(.minutes(1))) func oneActivationReadsOnceForTwoWindowsAndNotWithoutOne() async throws {
        await scriptTrio()
        let notifications = NotificationCenter()
        let (app, _) = app(notifications: notifications)
        let store = try #require(app.selectedStore)
        let start = Date()
        store.now = { start }
        await store.refresh()
        store.now = { start.addingTimeInterval(ScopeStore.freshness * 10) }
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1, "no window hosts live refresh")
        app.liveRefresh.attach()
        app.liveRefresh.attach()
        await scriptTrio()
        notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 2)
    }

    @Test(.timeLimit(.minutes(1))) func activationDuringAMutationRefreshDoesNothing() async throws {
        await scriptTrio()
        let (app, _) = app()
        let store = try #require(app.selectedStore)
        let start = Date()
        store.now = { start }
        await store.refresh()
        store.now = { start.addingTimeInterval(ScopeStore.freshness * 10) }
        let gate = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let mutationRefresh = Task { await store.refreshAfterMutation() }
        await gate.arrived()
        await app.liveRefresh.activated()
        #expect(await statusRuns() == 2)
        await gate.open()
        await mutationRefresh.value
        await app.liveRefresh.activated()
        #expect(await statusRuns() == 2, "within the settle window")
    }

    @Test(.timeLimit(.minutes(1))) func skippedWhileAMutationOfTheScopeRuns() async {
        let queue = MutationQueue()
        let gate = Gate()
        let (app, _) = app(queue: queue)
        let mutation = Task { [scope] in try await queue.enqueue(in: scope) { await gate.wait() } }
        await gate.arrived()
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        #expect(await client.commands.isEmpty)
        await gate.open()
        _ = try? await mutation.value
    }

    @Test(.timeLimit(.minutes(1))) func skippedRightAfterAMutationRefreshButNotLater() async throws {
        await scriptTrio()
        let (app, _) = app()
        let store = try #require(app.selectedStore)
        let start = Date()
        store.now = { start }
        await store.refreshAfterMutation()
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 1)
        await scriptTrio()
        store.now = { start.addingTimeInterval(ScopeStore.settleWindow + 1) }
        watcher.emit([reported("skills.lock")])
        await app.liveRefresh.settled()
        #expect(await statusRuns() == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aChangeInAProjectNotSetUpChecksTheManifestsAgain() async {
        let settings = SettingsStore(defaults: MemoryDefaults.make())
        settings.recentProjects = [project]
        let flag = ManifestFlag()
        let app = AppStore(
            settings: settings, client: client, capabilities: Capabilities(version: Capabilities.minimum),
            manifestExists: { _ in flag.value }, liveRefresh: LiveRefresh(watcher: watcher, debounce: .zero))
        await app.refreshSetUp()
        app.selectedScope = scope
        app.liveRefresh.follow()
        #expect(!app.isSetUp(scope))
        flag.value = true
        await scriptTrio()
        watcher.emit([reported("skills.toml")])
        await app.liveRefresh.settled()
        #expect(app.isSetUp(scope))
    }

    @Test(.timeLimit(.minutes(1))) func activationRefreshesAStaleScopeWithoutAnActivityRow() async throws {
        await scriptTrio()
        await scriptTrio()
        let (app, runner) = app()
        let store = try #require(app.selectedStore)
        let start = Date()
        store.now = { start }
        await store.refreshAfterMutation()
        await app.liveRefresh.activated()
        #expect(await statusRuns() == 1, "a fresh scope is not read again")
        // Past `freshness` however long the refresh itself took on a loaded machine.
        store.now = { Date().addingTimeInterval(ScopeStore.freshness + 1) }
        await app.liveRefresh.activated()
        #expect(await statusRuns() == 2)
        #expect(runner.activity.isEmpty)
    }
}

/// Whether the fake manifest check finds a skills.toml; flipped by the test, read off the main actor.
final class ManifestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
