import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The S2 list states (List-States, Running boards) as the pure `ListState` rule, over stores fed through the
/// `CLIClient` fake with the design fixtures; the hover controls per row kind; the selected-row styling rule.
@Suite @MainActor struct SkillListTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/skill-list-tests"))
    let capabilities = Capabilities(version: Capabilities.minimum)

    /// A store refreshed once from the fixture trio named `status`.
    func store(status: String = "status.api", outdated: Bool = true) async -> ScopeStore {
        await client.json(.status, in: scope, DesignFixtures.text(status, "json"))
        await client.json(.audit, in: scope, DesignFixtures.text("audit.api", "json"))
        await client.json(.doctor(fix: false), in: scope, DesignFixtures.text("doctor.api", "json"))
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        await store.refresh()
        if outdated {
            await client.json(.outdated, in: scope, DesignFixtures.text("outdated.api", "json"))
            await store.checkUpdates()
        }
        return store
    }

    // MARK: - ListState over stores

    @Test(.timeLimit(.minutes(1))) func rowsWhenTheScopeHasSkills() async {
        let store = await store()
        let state = ListState.resolve(store: store, running: nil)
        #expect(state.rows.count == 14)
        #expect(!state.isRefreshing)
        #expect(!state.isOffline)
        #expect(state.progressTitle == nil)
        #expect(state.chipCounts[.updates] == 3)
        #expect(state.dimmedFilters.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func emptyAfterSetUp() async {
        let store = await store(status: "status.empty", outdated: false)
        #expect(ListState.resolve(store: store, running: nil).content == .empty)
    }

    @Test(.timeLimit(.minutes(1))) func noMatchesEchoesTheQueryAndCountsAll() async {
        let store = await store()
        store.query = DesignFixtures.noMatchesQuery
        store.filter = .updates
        let state = ListState.resolve(store: store, running: nil)
        guard case .noMatches(let noMatches) = state.content else {
            Issue.record("expected no matches, got \(state.content)")
            return
        }
        #expect(noMatches.query == "postgres")
        #expect(noMatches.filter == .updates)
        #expect(noMatches.matchesInAll == Filter.all.apply(store.snapshot?.entries ?? [], query: "postgres").count)
        #expect(noMatches.showsShowAll)
        #expect(noMatches.showsClearSearch)
    }

    @Test(.timeLimit(.minutes(1))) func offlineHidesUpdatesInTheChipCounts() async {
        let store = await store()
        await client.script(
            .outdated, in: scope, .error(.failed(code: .network, message: "offline", hint: nil, stderr: "")))
        await store.checkUpdates()
        let state = ListState.resolve(store: store, running: nil)
        #expect(state.isOffline)
        #expect(state.chipCounts[.updates] == nil)
        #expect(state.chipCounts[.needsAttention] == store.snapshot?.attention.needing)
        #expect(state.dimmedFilters == [.updates])
        #expect(state.rows.count == 14)
    }

    @Test(.timeLimit(.minutes(1))) func refreshingKeepsRowsAndSaysChecking() async {
        let gate = Gate()
        let store = await store()
        await client.json(.status, in: scope, DesignFixtures.text("status.api", "json"), gate: gate)
        await client.json(.audit, in: scope, DesignFixtures.text("audit.api", "json"))
        await client.json(.doctor(fix: false), in: scope, DesignFixtures.text("doctor.api", "json"))
        store.selection = "pdf"
        let refresh = Task { await store.refresh() }
        await gate.arrived()
        let state = ListState.resolve(store: store, running: nil)
        #expect(state.isRefreshing)
        #expect(state.rows.count == 14)
        #expect(state.progressTitle == "Checking…")
        #expect(store.selection == "pdf")
        await gate.open()
        await refresh.value
    }

    // MARK: - Pure rule

    @Test func runningTitleWinsOverChecking() {
        let state = ListState.resolve(
            snapshot: DesignFixtures.api, filter: .all, query: "", sort: .state, isOffline: false, isRefreshing: true,
            runningTitle: "Syncing…")
        #expect(state.progressTitle == "Syncing…")
    }

    @Test func noSnapshotIsLoading() {
        let state = ListState.resolve(
            snapshot: nil, filter: .all, query: "", sort: .state, isOffline: false, isRefreshing: true)
        #expect(state.content == .loading)
    }

    @Test func anEmptyChipWithoutQueryOffersShowAllOnly() {
        let state = ListState.resolve(
            snapshot: DesignFixtures.website, filter: .notManaged, query: "", sort: .state, isOffline: false,
            isRefreshing: false)
        guard case .noMatches(let noMatches) = state.content else {
            Issue.record("expected no matches, got \(state.content)")
            return
        }
        #expect(noMatches.showsShowAll)
        #expect(!noMatches.showsClearSearch)
        #expect(noMatches.matchesInAll == DesignFixtures.website.entries.count)
        #expect(ListCopy.nothingIn(.notManaged) == "Nothing in Not managed")
        #expect(noMatches.body == nil)
    }

    @Test func aQueryEchoKeepsItsBody() {
        let noMatches = ListState.NoMatches(query: "postgres", filter: .updates, matchesInAll: 1)
        #expect(noMatches.body == "in Updates. 1 skill matches in All.")
    }

    // MARK: - Retry

    /// A runner whose `install` fails with `exit`, then (when scripted) succeeds; the refresh after each run is
    /// left unscripted, so it fails quietly into `refreshError`.
    func failingSync(exit: Int32, thenSucceeds: Bool) async -> (ActionRunner, ScopeStore) {
        await client.lines(.install(frozen: false), in: scope, [], exit: exit)
        if thenSucceeds {
            await client.lines(.install(frozen: false), in: scope, [])
        }
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store)
        return (runner, store)
    }

    func installs() async -> Int {
        await client.commands.filter { $0 == .install(frozen: false) }.count
    }

    @Test(.timeLimit(.minutes(1))) func integrityFailureIsNeverRetried() async {
        let (runner, _) = await failingSync(exit: 4, thenSucceeds: true)
        #expect(runner.banner?.isIntegrity == true)
        #expect(runner.retry() == nil)
        #expect(await installs() == 1)
        #expect(runner.banner != nil)
    }

    @Test(.timeLimit(.minutes(1))) func networkFailureRetriesOnceOnRequest() async {
        // The runner holds the store weakly (`AppStore` owns it in the app), so the test keeps it alive.
        let (runner, store) = await failingSync(exit: 3, thenSucceeds: true)
        #expect(runner.banner?.remedy == .retry)
        #expect(await installs() == 1)
        let task = runner.retry()
        #expect(task != nil)
        await task?.value
        #expect(await installs() == 2)
        #expect(runner.toast != nil)
        #expect(runner.retry() == nil)
        withExtendedLifetime(store) {}
    }

    @Test(.timeLimit(.minutes(1))) func theRunnerNeverRetriesOnItsOwn() async {
        let (runner, store) = await failingSync(exit: 3, thenSucceeds: true)
        await store.refresh()
        #expect(runner.banner != nil)
        #expect(await installs() == 1)
    }

    // MARK: - Hover controls

    nonisolated static let hover: [(SkillEntry, Bool, [SkillRowActions.MenuItem])] = [
        (DesignFixtures.pdf, true, [.remove, .revealInFinder]),
        (DesignFixtures.reviewPr, true, [.remove, .revealInFinder]),
        (DesignFixtures.commitMessage, false, [.remove, .revealInFinder]),
        (DesignFixtures.safeRefactor, false, [.revealInFinder]),
        (DesignFixtures.myNotes, false, [.revealInFinder]),
        (DesignFixtures.deployChecklist, false, [.revealInFinder]),
    ]

    @Test(arguments: hover)
    func hoverControlsPerRowKind(entry: SkillEntry, showsUpdate: Bool, menu: [SkillRowActions.MenuItem]) {
        let actions = SkillRowActions.resolve(entry, offline: false)
        #expect(actions.showsUpdate == showsUpdate, "\(entry.name)")
        #expect(actions.menu.filter { $0 != .revealInFinder } == menu.filter { $0 != .revealInFinder }, "\(entry.name)")
        #expect(actions.menu.contains(.revealInFinder) == (entry.path != nil), "\(entry.name)")
    }

    @Test func notManagedRowsOfferAdopt() {
        let actions = SkillRowActions.resolve(DesignFixtures.caveman, offline: false)
        #expect(actions.menu.contains(.adopt))
        #expect(actions.menu.contains(.remove))
        #expect(!actions.showsUpdate)
        #expect(!SkillRowActions.resolve(DesignFixtures.pdf, offline: false).menu.contains(.adopt))
    }

    @Test func offlineHidesUpdate() {
        #expect(SkillRowActions.resolve(DesignFixtures.pdf, offline: true).updatePackage == nil)
        #expect(SkillRowActions.resolve(DesignFixtures.pdf, offline: false).updatePackage == "anthropics/skills")
    }

    @Test func hoverWordsComeFromTheBoard() {
        #expect(ListCopy.update == "Update…")
        #expect(ListCopy.title(.remove) == "Remove…")
        #expect(ListCopy.title(.adopt) == "Adopt…")
        #expect(ListCopy.title(.revealInFinder) == "Reveal in Finder")
        #expect(ListCopy.searchPrompt(count: 0) == "Search skills")
        #expect(ListCopy.searchPrompt(count: 14) == "Search 14 skills  ⌘F")
    }

    // MARK: - Selected styling

    @Test func selectedStyleOnlyForASelectedRowInAnActiveWindow() {
        #expect(SkillRow.usesSelectedStyle(isSelected: true, active: true))
        #expect(!SkillRow.usesSelectedStyle(isSelected: true, active: false))
        #expect(!SkillRow.usesSelectedStyle(isSelected: false, active: true))
        #expect(!SkillRow.usesSelectedStyle(isSelected: false, active: false))
    }
}
