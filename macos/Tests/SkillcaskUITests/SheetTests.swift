import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The sheet scaffold: `SheetRun` over the real `ActionRunner` and a `CLIClient` fake (success closes with a toast,
/// a failure keeps the sheet open, Cancel stops the run), the routing of `AppStore.Sheet` to a sheet or the Remove
/// alert, the fixture boot's `SKILLCASK_UI_SHEET`, and the stub titles.
@Suite @MainActor struct SheetTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/sheet-tests"))
    let update = Invocation.Command.update(packages: ["acme/pdf"])

    func store() -> ScopeStore {
        ScopeStore(scope: scope, client: client, capabilities: Capabilities(version: Capabilities.minimum)) { _ in
            SkillText.parse("# fake")
        }
    }

    /// The offline trio the runner's refresh after a mutation asks for.
    func scriptRefresh() async {
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.4.0")]))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
    }

    // MARK: - SheetRun

    @Test(.timeLimit(.minutes(1))) func successClosesTheSheetAndLeavesTheToast() async {
        await client.lines(update, in: scope, ["Updating pdf 1.2.0 → 1.4.0 (packagist)…"])
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        let task = run.start(
            update, title: "Updating pdf…", outcome: { "Updated pdf in \($0)" }, in: store(), runner: runner,
            onSuccess: { closed = true })
        await task?.value
        #expect(closed && run.phase == .succeeded && run.canClose)
        #expect(runner.toast?.text == "Updated pdf in sheet-tests")
        #expect(runner.activity.first?.transcript == [.stdout("Updating pdf 1.2.0 → 1.4.0 (packagist)…")])
    }

    /// A sheet that stays open after exit 0 (Add Skill) starts without a toast and reads what the run said.
    @Test(.timeLimit(.minutes(1))) func aQuietStartLeavesNoToastAndKeepsWhatTheRunSaid() async {
        await client.lines(update, in: scope, ["Updating pdf 1.2.0 → 1.4.0 (packagist)…"])
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        #expect(run.headline == nil)
        var succeeded = false
        let task = run.start(
            update, title: "Updating pdf…", outcome: { "Updated pdf in \($0)" }, announce: false, in: store(),
            runner: runner, onSuccess: { succeeded = true })
        await task?.value
        #expect(succeeded && run.phase == .succeeded && runner.toast == nil)
        #expect(run.headline == "Updated pdf in sheet-tests" && run.runID == runner.activity.first?.id)
        let id = UUID()
        runner.announce("Updated pdf", emphasis: ["pdf"], id: id)
        #expect(runner.toast?.id == id && runner.toast?.emphasis == ["pdf"])
    }

    @Test(.timeLimit(.minutes(1))) func failureKeepsTheSheetOpenWithItsMessageAndNoBanner() async {
        await client.script(
            update, in: scope, .error(.failed(code: .network, message: "no route to host", hint: nil, stderr: "")))
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        let task = run.start(
            update, title: "Updating pdf…", outcome: { $0 }, in: store(), runner: runner, onSuccess: { closed = true })
        await task?.value
        #expect(!closed && run.canClose)
        #expect(run.failure?.title == OutcomeCopy.couldNot("Updating pdf…"))
        #expect(runner.banner == nil && runner.toast == nil, "the sheet shows the failure, not the list column")
        #expect(runner.retry() == nil, "the banner's Retry does not re-run a sheet's command")
        #expect(runner.activity.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancelStopsTheRunAndTheHeaderLeavesItToTheSheet() async {
        let gate = Gate()
        await client.lines(update, in: scope, [], gate: gate)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let store = store()
        let run = SheetRun()
        let task = run.start(update, title: "Updating pdf…", outcome: { $0 }, in: store, runner: runner, onSuccess: {})
        await gate.arrived()
        #expect(run.canCancel && !run.canClose && run.action?.title == "Updating pdf…")
        #expect(ListState.resolve(store: store, running: runner.current).progressTitle == nil)
        #expect(run.start(update, title: "again", outcome: { $0 }, in: store, runner: runner, onSuccess: {}) == nil)
        run.cancel()
        await gate.open()
        await task?.value
        #expect(run.failure?.reason == ErrorCopy.cancelled && run.canClose && runner.current == nil)
        #expect(await client.commands.suffix(3).contains(.status), "the refresh after Cancel still ran")
        #expect(!store.isRefreshing)
    }

    /// Cancel from the window (the list header's run) also leaves a finished refresh behind.
    @Test(.timeLimit(.minutes(1))) func aCancelledWindowRunStillRefreshes() async {
        let gate = Gate()
        await client.lines(.install(frozen: false), in: scope, [], gate: gate)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let store = store()
        let sync = Task { await runner.sync(in: store) }
        await gate.arrived()
        runner.cancel()
        await gate.open()
        await sync.value
        let commands = await client.commands
        #expect(Set(commands.suffix(3)) == [.status, .audit, .doctor(fix: false)])
        #expect(!store.isRefreshing && store.snapshot != nil)
        #expect(runner.banner?.reason == ErrorCopy.cancelled)
    }

    /// An older refresh that returns after a newer one started leaves the newer one's flag on.
    @Test(.timeLimit(.minutes(1))) func aSupersededRefreshKeepsTheNewerFlag() async {
        let first = Gate()
        let second = Gate()
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: first)
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.4.0")]), gate: second)
        for _ in 0..<2 {
            await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
            await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        }
        let store = store()
        let older = Task { await store.refresh() }
        await first.arrived()
        let newer = Task { await store.refresh() }
        await second.arrived()
        await first.open()
        await older.value
        #expect(store.isRefreshing, "the older refresh does not clear the newer one's flag")
        await second.open()
        await newer.value
        #expect(!store.isRefreshing && store.snapshot?.entries.first?.version == "1.4.0")
    }

    @Test(.timeLimit(.minutes(1))) func aSheetCannotStartWhileTheWindowRuns() async {
        let gate = Gate()
        await client.lines(.install(frozen: false), in: scope, [], gate: gate)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let store = store()
        let sync = Task { await runner.sync(in: store) }
        await gate.arrived()
        let run = SheetRun()
        #expect(
            run.start(update, title: "Updating pdf…", outcome: { $0 }, in: store, runner: runner, onSuccess: {}) == nil)
        #expect(
            run.phase == .failed(SheetRun.refusal(failure: OutcomeCopy.couldNot("Updating pdf…"))),
            "the sheet says why nothing started")
        #expect(run.failure?.reason == SheetCopy.anotherRunInFlight && run.canClose)
        #expect(ListState.resolve(store: store, running: runner.current).progressTitle == ActionCopy.syncing)
        await gate.open()
        await sync.value
    }

    /// Cancel pressed before the runner has started the command is not lost.
    @Test(.timeLimit(.minutes(1))) func cancelBeforeTheRunStartsIsKept() async {
        let gate = Gate()
        await client.lines(update, in: scope, [], gate: gate)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        let task = run.start(
            update, title: "Updating pdf…", outcome: { $0 }, in: store(), runner: runner, onSuccess: { closed = true })
        run.cancel()
        await gate.open()
        await task?.value
        #expect(!closed && run.failure?.reason == ErrorCopy.cancelled && runner.current == nil)
    }

    /// A sheet's failure (or success) leaves the window's banner and its Retry as they were.
    @Test(.timeLimit(.minutes(1))) func aSheetRunKeepsTheWindowRetry() async {
        await client.script(
            .install(frozen: false), in: scope,
            .error(.failed(code: .network, message: "no route to host", hint: nil, stderr: "")))
        await scriptRefresh()
        await client.script(update, in: scope, .error(.failed(code: .other(1), message: "boom", hint: nil, stderr: "")))
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let store = store()
        await runner.sync(in: store)
        let banner = runner.banner
        #expect(banner != nil)
        await run(update, in: store, runner: runner)
        #expect(runner.banner == banner, "the sheet's failure does not replace the window's banner")
        await client.lines(.install(frozen: false), in: scope, [])
        await scriptRefresh()
        #expect(runner.retry() != nil, "Retry still re-runs the window's sync")
    }

    func run(_ command: Invocation.Command, in store: ScopeStore, runner: ActionRunner) async {
        await SheetRun()
            .start(command, title: "Updating pdf…", outcome: { $0 }, in: store, runner: runner, onSuccess: {})?
            .value
    }

    // MARK: - Batch

    func adopt(_ skill: String) -> Invocation.Command {
        .add(spec: "github:acme/\(skill)", repository: nil, adopt: true, rename: [:], skills: [])
    }

    func startBatch(
        _ skills: [String], _ run: SheetRun, store: ScopeStore, runner: ActionRunner,
        onSuccess: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        run.startBatch(
            skills, title: "Adopting \(skills.count) skills…", command: adopt, itemTitle: { "Adopting \($0)…" },
            summary: { done, scope in "Adopted \(done) skills in \(scope)" }, in: store, runner: runner,
            onSuccess: onSuccess)
    }

    @Test(.timeLimit(.minutes(1))) func aBatchRunsInOrderWithOneToastAndClosesAtTheEnd() async {
        for skill in ["a", "b", "c"] {
            await client.lines(adopt(skill), in: scope, ["Adopted \(skill)"])
            await scriptRefresh()
        }
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        await startBatch(["a", "b", "c"], run, store: store(), runner: runner) { closed = true }?.value
        let commands = await client.commands.filter { if case .add = $0 { true } else { false } }
        #expect(commands == [adopt("a"), adopt("b"), adopt("c")])
        #expect(run.phase == .succeeded && closed && run.doneCount == 3)
        #expect(run.items.allSatisfy { if case .done = $0.state { true } else { false } })
        #expect(runner.toast?.text == "Adopted 3 skills in sheet-tests")
        #expect(runner.activity.count == 3)
    }

    @Test(.timeLimit(.minutes(1))) func aFailureStopsTheRestAndKeepsTheSheetOpen() async {
        await client.lines(adopt("a"), in: scope, [])
        await scriptRefresh()
        await client.script(
            adopt("b"), in: scope, .error(.failed(code: .other(1), message: "no", hint: nil, stderr: "")))
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        await startBatch(["a", "b", "c"], run, store: store(), runner: runner) { closed = true }?.value
        #expect(!closed && run.failure != nil && run.canClose)
        #expect(run.items.map(\.state.isSkipped) == [false, false, true])
        #expect(runner.toast?.text == "Adopted 1 skills in sheet-tests" && runner.banner == nil)
        #expect(!(await client.commands.contains(adopt("c"))))
    }

    @Test(.timeLimit(.minutes(1))) func cancelStopsAfterTheCurrentItem() async {
        let gate = Gate()
        await client.lines(adopt("a"), in: scope, [], gate: gate)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        let task = startBatch(["a", "b"], run, store: store(), runner: runner) { closed = true }
        await gate.arrived()
        #expect(!run.canClose && run.items.first?.state == .running)
        run.cancel()
        await gate.open()
        await task?.value
        #expect(run.phase == .stopped && !closed && run.canClose)
        #expect(run.doneCount == 1 && run.items.last?.state == .skipped)
        #expect(!(await client.commands.contains(adopt("b"))))
        #expect(runner.toast?.text == "Adopted 1 skills in sheet-tests")
    }

    /// Another run slipping in between two items fails that item with the refusal and skips the rest.
    @Test(.timeLimit(.minutes(1))) func aRefusalMidBatchFailsTheItemAndSkipsTheRest() async {
        let refresh = Gate()
        let sync = Gate()
        await client.lines(adopt("a"), in: scope, [])
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]), gate: refresh)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await client.lines(.install(frozen: false), in: scope, [], gate: sync)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let store = store()
        let run = SheetRun()
        let batch = startBatch(["a", "b", "c"], run, store: store, runner: runner, onSuccess: {})
        await refresh.arrived()
        let window = Task { await runner.sync(in: store) }
        await sync.arrived()
        await refresh.open()
        await batch?.value
        #expect(run.failure == SheetRun.refusal(failure: OutcomeCopy.couldNot("Adopting b…")))
        #expect(run.items.map(\.state.isSkipped) == [false, false, true] && run.doneCount == 1)
        await sync.open()
        await window.value
    }

    @Test func anOrphanedPresentationIsDropped() {
        let shown = AppStore.Presentation(id: UUID(), sheet: .remove(skills: ["pdf"]), scope: scope)
        #expect(AppStore.orphan(shown, hasStore: { _ in false }) == shown)
        #expect(AppStore.orphan(shown, hasStore: { _ in true }) == nil)
        #expect(AppStore.orphan(nil, hasStore: { _ in false }) == nil)
        let app = app()
        #expect(app.request(.remove(skills: ["pdf"])))
        app.dropOrphanedPresentation()
        #expect(app.removal != nil, "a presentation whose store exists stays")
    }

    @Test func droppingOrphansBuildsNoStore() {
        let app = app()
        #expect(app.removeFromSidebar(scope))
        #expect(app.visitedStore(for: scope) == nil)
        #expect(
            !app.hasStore(for: scope), "a scope out of the sidebar has no store on screen, though one could be built")
        #expect(app.hasStore(for: .personal))
        app.dropOrphanedPresentation()
        #expect(app.visitedStore(for: scope) == nil, "the orphan check does not bring the forgotten store back")
    }

    /// Settings is a window of its own: Clear Recent, Choose… and "Use the detected one" stay clickable while the
    /// main window shows a sheet. The project the sheet is pinned to stays in the sidebar, and the tool is not
    /// changed under it (both would drop the store the sheet works on).
    @Test func aPinnedScopeKeepsItsStoreWhileTheSheetIsUp() async throws {
        let app = app()
        #expect(app.request(.adopt(skills: ["caveman"])))
        let pinned = try #require(app.visitedStore(for: scope))
        #expect(!app.canRemoveFromSidebar(scope) && !app.removeFromSidebar(scope))
        #expect(app.isListed(scope) && app.visitedStore(for: scope) === pinned)
        #expect(!app.canChangeBinary)
        #expect(await app.locate(executable: URL(fileURLWithPath: "/tmp/other/skillcask")) == .cancelled)
        await app.useDetectedBinary()
        #expect(app.isReady && app.visitedStore(for: scope) === pinned && app.presentedSheet != nil)
        app.dropOrphanedPresentation()
        #expect(app.presentedSheet != nil, "the pinned scope is listed and the CLI ready: not an orphan")
        app.dismiss(try #require(app.presentedSheet))
        #expect(app.canChangeBinary && app.removeFromSidebar(scope))
    }

    /// A presentation pinned to a scope the sidebar no longer lists is an orphan, even with the CLI ready.
    @Test func aPresentationOfAnUnlistedScopeIsAnOrphan() throws {
        let app = app()
        app.selectedScope = .project(URL(fileURLWithPath: "/tmp/sheet-tests-unlisted"))
        #expect(app.request(.adopt(skills: ["caveman"])))
        app.dropOrphanedPresentation()
        #expect(app.presentation == nil)
    }

    // MARK: - Routing

    func app() -> AppStore {
        let defaults = UserDefaults(suiteName: "SheetTests-\(UUID().uuidString)") ?? .standard
        let settings = SettingsStore(defaults: defaults)
        settings.remember(project: scope.root)
        let app = AppStore(
            settings: settings, client: client, capabilities: Capabilities(version: Capabilities.minimum))
        app.selectedScope = scope
        return app
    }

    @Test func removeIsAnAlertAndEveryOtherRequestASheet() throws {
        let app = app()
        #expect(app.request(.adopt(skills: ["caveman"])))
        let adopt = try #require(app.presentedSheet)
        #expect(adopt.sheet == .adopt(skills: ["caveman"]) && adopt.scope == scope && app.removal == nil)
        app.dismiss(adopt)
        #expect(app.request(.remove(skills: ["pdf", "review-pr"])))
        #expect(app.presentedSheet == nil && app.removal?.sheet == .remove(skills: ["pdf", "review-pr"]))
    }

    /// While a sheet or the alert is up every other request is refused, so a shortcut cannot replace it.
    @Test func aRequestIsRefusedWhileOneIsPresented() throws {
        let app = app()
        #expect(app.request(.update(package: "acme/pdf")))
        let shown = try #require(app.presentation)
        #expect(app.isPresenting)
        #expect(!app.request(.addSkill(query: nil)))
        #expect(!app.request(.remove(skills: ["pdf"])))
        #expect(app.presentation == shown)
        app.dismiss(shown)
        #expect(!app.isPresenting && app.request(.remove(skills: ["pdf"])))
        #expect(!app.request(.updateAll), "the alert blocks a sheet too")
    }

    /// The presentation keeps the scope it was asked for; switching the sidebar does not rebind it.
    @Test func thePresentationIsPinnedToItsScope() throws {
        let app = app()
        #expect(app.request(.adopt(skills: ["caveman"])))
        let other = Scope.project(URL(fileURLWithPath: "/tmp/sheet-tests-other"))
        app.selectedScope = other
        let shown = try #require(app.presentedSheet)
        #expect(shown.scope == scope)
        #expect(app.store(for: shown.scope)?.scope == scope)
    }

    /// A close clears only its own presentation: a late `onSuccess` of an old sheet leaves the new one up.
    @Test func aStaleCloseLeavesTheNewPresentationAlone() throws {
        let app = app()
        #expect(app.request(.updateAll))
        let first = try #require(app.presentation)
        app.dismiss(first)
        #expect(app.request(.addSkill(query: nil)))
        app.dismiss(first)
        #expect(app.presentedSheet?.sheet == .addSkill(query: nil))
    }

    @Test func nothingIsPresentedWithoutAScope() {
        let app = app()
        app.selectedScope = nil
        #expect(!app.request(.updateAll) && app.presentation == nil)
    }

    @Test func updateForAnEntryCarriesTheOfferedVersionAndReviewOnly() throws {
        let pdf = try #require(DesignFixtures.api.entries.first { $0.id == "pdf" })
        #expect(
            AppStore.Sheet.update(for: pdf) == .update(package: "anthropics/skills", target: "1.4.0", reviewOnly: false)
        )
        guard case .update(_, _, let reviewOnly) = AppStore.Sheet.update(for: DesignFixtures.managedCaveman) else {
            Issue.record("not an update")
            return
        }
        #expect(reviewOnly, "a moved tag never makes Update the default")
        #expect(AppStore.Sheet.update(package: "a/b") == .update(package: "a/b", target: nil, reviewOnly: false))
    }

    /// Remove… is ⌘⌫ (Remove board), never a plain ⌫ that would fire while typing.
    @Test func removeIsCommandDelete() {
        #expect(SkillcaskCommands.removeShortcut.key == .delete)
        #expect(SkillcaskCommands.removeShortcut.modifiers == .command)
    }

    // MARK: - Fixture boot

    @Test(arguments: [
        ("update:pdf", AppStore.Sheet.update(package: "pdf")),
        ("update:acme/pdf@1.4.0", .update(package: "acme/pdf", target: "1.4.0", reviewOnly: false)),
        ("update-all", .updateAll),
        ("add", .addSkill(query: nil)),
        ("add:jira", .addSkill(query: "jira")),
        ("adopt:caveman,pdf", .adopt(skills: ["caveman", "pdf"])),
        ("remove:pdf", .remove(skills: ["pdf"])),
    ])
    func theFixtureBootOpensTheNamedSheet(argument: String, sheet: AppStore.Sheet) {
        #expect(Boot.sheet(from: argument) == sheet)
    }

    @Test(arguments: [nil, "", "update", "adopt", "remove:", "update-all:x", "share"])
    func anUnknownSheetArgumentOpensNothing(argument: String?) {
        #expect(Boot.sheet(from: argument) == nil)
    }

    @Test func fixturesCanOpenASheet() {
        let stores = Boot.fixtures(sheet: .addSkill(query: "jira"))
        #expect(stores.app.presentedSheet?.sheet == .addSkill(query: "jira"))
        #expect(stores.app.presentedSheet?.scope == Boot.apiScope)
    }

    // MARK: - Stub copy

    @Test func stubTitlesAreTheBoards() {
        #expect(ReviewUpdateCopy.title(package: "pdf") == "Update pdf")
        #expect(ReviewUpdateCopy.title(package: "pdf", from: "1.2.0", to: "1.4.0") == "Update pdf 1.2.0 → 1.4.0")
        #expect(AddSkillCopy.title(scopeName: "api") == "Add Skill to api")
        #expect(AdoptCopy.title(skills: ["caveman"]) == "Adopt caveman")
        #expect(AdoptCopy.title(skills: Array(repeating: "x", count: 12)) == "Adopt 12 skills")
        #expect(RemoveCopy.title(skills: ["pdf"], personal: false) == "Remove pdf from this project?")
        #expect(RemoveCopy.title(skills: ["caveman"], personal: true) == "Remove caveman from My Skills?")
        #expect(RemoveCopy.title(skills: ["a", "b", "c"], personal: false) == "Remove 3 skills from this project?")
        #expect(RemoveCopy.button(count: 1) == "Remove" && RemoveCopy.button(count: 3) == "Remove 3 Skills")
    }
}

extension SheetRun.Item.State {
    fileprivate var isSkipped: Bool {
        self == .skipped
    }
}
