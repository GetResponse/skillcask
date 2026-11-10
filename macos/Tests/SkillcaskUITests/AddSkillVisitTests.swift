import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// One visit to the Add Skill sheet (`AddSkillVisit`, S11): an add that exits 0 leaves the sheet open with its
/// search, marks the row Installed after the refresh and says what it added in the footer; no toast shows until the
/// sheet closes, which then leaves one (the add's own, or a summary of several) and selects the last added skill;
/// a failure keeps what was added before it; the add that just succeeded cannot be repeated by accident. The sheet
/// draws `footer` and `closeTitle`, moves the keyboard to `focusAfterRun` and calls `cancelOrClose` and
/// `disappeared`: what those say and do is pinned here, the view itself is not tested.
@Suite @MainActor struct AddSkillVisitTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/add-visit-tests"))
    let runner = ActionRunner(queue: MutationQueue())
    /// How often the visit closed its sheet (`AddSkillSheet`'s `onClose`).
    let closes = Counter()
    static let cli = Added(package: "atlassian/jira-cli-skill", skill: "jira-cli", version: "2.1.0")
    static let markdown = Added(package: "kolya/jira-to-md", skill: "jira-to-md", version: "0.9.0")
    static let german = Added(
        package: "netresearch/german-technical-writing-skill", skill: "german-writing", version: "1.0.0")
    static let capable = Capabilities(version: Capabilities.minimum, features: [.addSkill, .addRename])

    @MainActor final class Counter {
        var count = 0
    }

    struct Added {
        let package: String
        let skill: String
        let version: String
    }

    /// A visit over the api board's snapshot with the jira results loaded, filtered to Packagist.
    func visit(capabilities: Capabilities = Capabilities(version: Capabilities.minimum)) -> AddSkillVisit {
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        store.preload(snapshot: DesignFixtures.api)
        let search = SearchStore(store: store, debounce: .zero)
        search.preload(query: "jira", results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled)
        search.sourceFilter = "packagist"
        return AddSkillVisit(search: search) { [closes] in closes.count += 1 }
    }

    static func status(_ installed: [Added]) -> String {
        let entries = installed.map {
            #"{"package":"\#($0.package)","skill":"\#($0.skill)","version":"\#($0.version)","state":"ok","ok":true}"#
        }
        return #"{"ok":true,"entries":[\#(entries.joined(separator: ","))],"policy":{},"repositories":[]}"#
    }

    static func info(_ added: Added, skills: [String]? = nil) -> String {
        let skills = (skills ?? [added.skill]).map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        return
            #"{"package":"\#(added.package)","version":"\#(added.version)","locked":false,"skills":[\#(skills)],"#
            + #""versions":["\#(added.version)"]}"#
    }

    /// Selects `added`'s result and loads its preview.
    func select(_ added: Added, in visit: AddSkillVisit, skills: [String]? = nil) async {
        await client.json(.info(.package(added.package)), in: scope, Self.info(added, skills: skills))
        visit.search.selection = added.package
        await visit.search.infoTask?.value
    }

    /// The trio the runner's refresh reads after an add, with `installed` in the lock.
    func scriptRefresh(_ installed: [Added]) async {
        await client.json(.status, in: scope, Self.status(installed))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
    }

    /// Selects `added` and adds it at exit 0; `installed` is what the lock holds afterwards.
    @discardableResult func add(
        _ added: Added, in visit: AddSkillVisit, installed: [Added]
    ) async throws -> Invocation.Command {
        await select(added, in: visit)
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added \#(added.package) = "^1" (\#(added.version))"#])
        await scriptRefresh(installed)
        await visit.add(runner: runner)?.value
        return command
    }

    func adds() async -> [Invocation.Command] {
        await client.commands.filter { if case .add = $0 { true } else { false } }
    }

    // MARK: - Success

    @Test(.timeLimit(.minutes(1))) func aSuccessfulAddKeepsTheSheetOpenWithItsSearch() async throws {
        let visit = visit()
        let results = visit.search.results
        #expect(visit.status == nil && visit.closeTitle == "Cancel" && visit.focusAfterRun == .field)
        #expect(visit.footer == .note(AddSkillCopy.footerProject))
        try await add(Self.cli, in: visit, installed: [Self.cli])
        #expect(visit.run.phase == .succeeded && visit.run.canClose)
        #expect(closes.count == 0, "exit 0 does not close the sheet")
        #expect(runner.toast == nil, "no toast over an open sheet")
        #expect(visit.search.query == "jira" && visit.search.sourceFilter == "packagist")
        #expect(visit.search.results == results && visit.search.filteredResults.count == 5)
        #expect(visit.search.selection == Self.cli.package, "the selection stays on the added row")
        #expect(visit.focusAfterRun == .results, "the keyboard goes back to the list: Down and Return add the next")
        #expect(visit.announcementAfterRun == "Added jira-cli (2.1.0)", "VoiceOver hears it after the focus moved")
        #expect(visit.status == "Added jira-cli (2.1.0)")
        #expect(visit.footer == .added(text: "Added jira-cli (2.1.0)", emphasis: ["jira-cli"], count: nil))
        #expect(visit.closeTitle == "Done")
        #expect(runner.activity.first?.headline == "Added jira-cli (2.1.0)")
        #expect(runner.activity.first?.title == "Adding atlassian/jira-cli-skill…")
    }

    @Test(.timeLimit(.minutes(1))) func theInstalledMarkerAppearsOnTheAddedRowOfTheOpenSheet() async throws {
        let visit = visit()
        let row = try #require(visit.search.filteredResults.first { $0.name == Self.cli.package })
        #expect(!visit.search.isInstalled(row) && visit.search.installedSkills(of: row).isEmpty)
        try await add(Self.cli, in: visit, installed: [Self.cli])
        #expect(visit.search.isInstalled(row), "read from the scope's snapshot, refreshed after the add")
        #expect(visit.search.installedSkills(of: row) == ["jira-cli"])
    }

    @Test(.timeLimit(.minutes(1))) func aTypedSourceKeepsTheKeyboardInTheField() async throws {
        let source = "github:acme/jira"
        let visit = visit()
        await client.json(.info(.package(source)), in: scope, #"{"package":"acme/jira","skills":[{"name":"jira"}]}"#)
        visit.search.preload(query: source, selection: source)
        visit.search.retryPreview()
        await visit.search.infoTask?.value
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added acme/jira = "main" (3f2a9c1d0b7e)"#])
        await scriptRefresh([Added(package: "acme/jira", skill: "jira", version: "3f2a9c1d0b7e")])
        await visit.add(runner: runner)?.value
        #expect(visit.status == "Added jira (3f2a9c1d0b7e)")
        #expect(visit.focusAfterRun == .field, "there is no list to return to")
    }

    // MARK: - One run at a time

    @Test(.timeLimit(.minutes(1))) func theNextAddWaitsForTheRunToEnd() async throws {
        let visit = visit()
        await select(Self.cli, in: visit)
        let command = try #require(visit.search.command)
        let gate = Gate()
        await client.lines(command, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#], gate: gate)
        await scriptRefresh([Self.cli])
        let task = visit.add(runner: runner)
        await gate.arrived()
        #expect(!visit.canAdd && visit.add(runner: runner) == nil, "no queue")
        #expect(visit.closeTitle == "Cancel" && !visit.run.canClose)
        await gate.open()
        await task?.value
        #expect(await adds() == [command])
    }

    // MARK: - Closing

    @Test(.timeLimit(.minutes(1))) func closingAfterOneAddLeavesItsToastAndSelectsTheSkill() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        await visit.close(runner: runner)?.value
        let toast = try #require(runner.toast)
        #expect(toast.text == "Added jira-cli (2.1.0)" && toast.emphasis == ["jira-cli"])
        #expect(toast.id == runner.activity.first?.id, "Show details opens the add's run")
        #expect(visit.search.store.selection == "jira-cli")
        runner.toast = nil
        #expect(visit.close(runner: runner) == nil && runner.toast == nil, "one close, one toast")
    }

    @Test(.timeLimit(.minutes(1))) func closingAfterSeveralAddsLeavesOneSummaryAndSelectsTheLast() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        try await add(Self.markdown, in: visit, installed: [Self.cli, Self.markdown])
        #expect(visit.status == "Added jira-to-md (0.9.0) · 2 skills added")
        #expect(
            visit.footer
                == .added(text: "Added jira-to-md (0.9.0)", emphasis: ["jira-to-md"], count: "· 2 skills added"),
            "the count is its own part: the footer never truncates it")
        try await add(Self.german, in: visit, installed: [Self.cli, Self.markdown, Self.german])
        #expect(visit.status == "Added german-writing (1.0.0) · 3 skills added")
        #expect(runner.toast == nil)
        await visit.close(runner: runner)?.value
        #expect(runner.toast?.text == "Added 3 skills to add-visit-tests")
        #expect(visit.search.store.selection == "german-writing", "the last one added")
        #expect(runner.activity.count == 3)
    }

    @Test func closingWithoutAnAddLeavesNothing() {
        let visit = visit()
        #expect(visit.close(runner: runner) == nil)
        #expect(runner.toast == nil && visit.search.store.selection == nil)
    }

    /// The sheet went away under a run (its scope left the sidebar): the add still gets its toast.
    @Test(.timeLimit(.minutes(1))) func anAddThatEndsAfterTheSheetClosedToastsAtOnce() async throws {
        let visit = visit()
        await select(Self.cli, in: visit)
        let command = try #require(visit.search.command)
        let gate = Gate()
        await client.lines(command, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#], gate: gate)
        await scriptRefresh([Self.cli])
        let task = visit.add(runner: runner)
        await gate.arrived()
        #expect(visit.close(runner: runner) == nil && runner.toast == nil)
        await gate.open()
        await task?.value
        #expect(runner.toast?.text == "Added jira-cli (2.1.0)")
    }

    /// One add is in, a second is running, and the sheet goes away under it: the toast of the first is replaced by
    /// one for the whole visit when the second ends, and the selection follows.
    @Test(.timeLimit(.minutes(1))) func aLaterAddThatEndsAfterTheSheetClosedCompletesTheSummary() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        await select(Self.markdown, in: visit)
        let command = try #require(visit.search.command)
        let gate = Gate()
        await client.lines(command, in: scope, [#"added kolya/jira-to-md = "^0.9" (0.9.0)"#], gate: gate)
        await scriptRefresh([Self.cli, Self.markdown])
        let task = visit.add(runner: runner)
        await gate.arrived()
        visit.disappeared(runner: runner)
        #expect(runner.toast?.text == "Added jira-cli (2.1.0)", "what was added when the sheet went away")
        await gate.open()
        await task?.value
        #expect(runner.toast?.text == "Added 2 skills to add-visit-tests", "one toast for the whole visit")
        #expect(visit.search.store.selection == "jira-to-md", "the last one added")
    }

    @Test(.timeLimit(.minutes(1))) func anAddWithoutKnownSkillsToastsAndSelectsNothing() async throws {
        let source = "github:acme/jira"
        let visit = visit()
        await client.json(.info(.package(source)), in: scope, #"{"package":"acme/jira","skills":[]}"#)
        visit.search.preload(query: source, selection: source)
        visit.search.retryPreview()
        await visit.search.infoTask?.value
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added acme/jira = "main" (3f2a9c1d0b7e)"#])
        await scriptRefresh([])
        await visit.add(runner: runner)?.value
        #expect(visit.status == "Added github:acme/jira" && visit.skillCount == 1)
        #expect(visit.close(runner: runner) == nil, "no skill to select")
        #expect(runner.toast?.text == "Added github:acme/jira" && runner.toast?.emphasis == [])
        #expect(visit.search.store.selection == nil)
    }

    // MARK: - The sheet's buttons

    @Test func cancelBeforeAnyAddClosesWithoutAToast() {
        let visit = visit()
        visit.cancelOrClose(runner: runner)
        #expect(closes.count == 1 && runner.toast == nil)
    }

    @Test(.timeLimit(.minutes(1))) func doneClosesOnceWithTheToastAndDisappearingAddsNothing() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        let selection = visit.cancelOrClose(runner: runner)
        #expect(closes.count == 1 && runner.toast?.text == "Added jira-cli (2.1.0)")
        runner.toast = nil
        #expect(visit.cancelOrClose(runner: runner) == nil && closes.count == 1, "a second click on Done")
        #expect(visit.disappeared(runner: runner) == nil)
        #expect(closes.count == 1 && runner.toast == nil, "the button already said it")
        await selection?.value
        #expect(visit.search.store.selection == "jira-cli")
    }

    /// Esc with a system dismissal, or the scope leaving the sidebar: no button ran.
    @Test(.timeLimit(.minutes(1))) func disappearingAloneLeavesTheToastAndEndsTheSearch() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        visit.disappeared(runner: runner)
        #expect(runner.toast?.text == "Added jira-cli (2.1.0)" && closes.count == 0)
        visit.search.query = "jira triage"
        await visit.search.searchTask?.value
        #expect(await client.commands.allSatisfy { if case .search = $0 { false } else { true } }, "nothing new runs")
    }

    /// Cancel during a later run stops that run and nothing else: the sheet stays, with what was added before.
    @Test(.timeLimit(.minutes(1))) func cancelDuringALaterRunStopsItAndKeepsTheEarlierAdd() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        #expect(visit.closeTitle == "Done")
        await select(Self.markdown, in: visit)
        let command = try #require(visit.search.command)
        let gate = Gate()
        await client.lines(command, in: scope, [], gate: gate)
        await scriptRefresh([Self.cli])
        let task = visit.add(runner: runner)
        await gate.arrived()
        #expect(visit.closeTitle == "Cancel", "while a run is in flight the button stops it")
        visit.cancelOrClose(runner: runner)
        #expect(closes.count == 0)
        await gate.open()
        await task?.value
        #expect(visit.run.failure?.reason == ErrorCopy.cancelled && visit.focusAfterRun == .field)
        #expect(visit.status == "Added jira-cli (2.1.0)" && visit.closeTitle == "Done")
        visit.cancelOrClose(runner: runner)
        #expect(closes.count == 1 && runner.toast?.text == "Added jira-cli (2.1.0)", "only what was added")
    }

    /// Updates were checked in this scope, so each refresh ends with `outdated`. The first add's refresh is still
    /// reading it when the second add ends and the sheet closes: it lands with a status from before the second
    /// add, and the scope drops a selection that status does not know. The selection is made again once the
    /// refreshes have landed.
    @Test(.timeLimit(.minutes(1))) func theSelectionSurvivesARefreshFromBeforeTheLastAdd() async throws {
        let outdated = #"{"packages":[],"behind":[]}"#
        let visit = visit()
        let store = visit.search.store
        await scriptRefresh([])
        await client.json(.outdated, in: scope, outdated)
        await store.refresh()
        await store.checkUpdates()
        // The first add: its refresh reads the status, then waits in `outdated`.
        await select(Self.cli, in: visit)
        let first = try #require(visit.search.command)
        await client.lines(first, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#])
        await scriptRefresh([Self.cli])
        let firstCheck = Gate()
        await client.json(.outdated, in: scope, outdated, gate: firstCheck)
        let firstTask = visit.add(runner: runner)
        await firstCheck.arrived()
        // The second add: its refresh waits in `status`.
        await select(Self.markdown, in: visit)
        let second = try #require(visit.search.command)
        await client.lines(second, in: scope, [#"added kolya/jira-to-md = "^0.9" (0.9.0)"#])
        let secondStatus = Gate()
        await client.json(.status, in: scope, Self.status([Self.cli, Self.markdown]), gate: secondStatus)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await client.json(.outdated, in: scope, outdated)
        let secondTask = visit.add(runner: runner)
        await secondStatus.arrived()
        // Done, right after the second add ended.
        let selection = visit.cancelOrClose(runner: runner)
        #expect(runner.toast?.text == "Added 2 skills to add-visit-tests")
        await firstCheck.open()
        await firstTask?.value
        #expect(store.snapshot?.entry(id: "jira-to-md") == nil, "the first refresh knows the first add only")
        await secondStatus.open()
        await secondTask?.value
        await selection?.value
        #expect(store.selection == "jira-to-md" && store.snapshot?.entry(id: "jira-to-md") != nil)
    }

    // MARK: - Failure

    @Test(.timeLimit(.minutes(1))) func aFailureAfterTwoAddsKeepsTheirStatusAndCount() async throws {
        let visit = visit()
        try await add(Self.cli, in: visit, installed: [Self.cli])
        try await add(Self.markdown, in: visit, installed: [Self.cli, Self.markdown])
        await select(Self.german, in: visit)
        let command = try #require(visit.search.command)
        await client.script(
            command, in: scope,
            .error(.failed(code: .network, message: "Couldn’t reach packagist.", hint: nil, stderr: "")))
        await scriptRefresh([Self.cli, Self.markdown])
        await visit.add(runner: runner)?.value
        let failure = try #require(visit.run.failure)
        #expect(failure.title == "Couldn’t add netresearch/german-technical-writing-skill.")
        #expect(FailureBanner.showsRetry(failure) && runner.banner == nil && runner.toast == nil)
        #expect(visit.status == "Added jira-to-md (0.9.0) · 2 skills added")
        #expect(visit.closeTitle == "Done" && visit.canAdd, "Retry runs the same add again")
        #expect(visit.focusAfterRun == .field, "after a failure the field has the keyboard, as before")
        #expect(visit.announcementAfterRun == nil, "the failure is on screen; nothing new was added")
        await visit.close(runner: runner)?.value
        #expect(runner.toast?.text == "Added 2 skills to add-visit-tests", "only what was added")
        #expect(visit.search.store.selection == "jira-to-md")
    }

    // MARK: - Repeat

    /// The selection stays on the added row, so Return would run the same `add` again: the CLI would resolve the
    /// package once more, rewrite its entry and print `added` a second time.
    @Test(.timeLimit(.minutes(1))) func theAddThatJustSucceededIsNotRepeated() async throws {
        let visit = visit()
        let command = try await add(Self.cli, in: visit, installed: [Self.cli])
        #expect(visit.search.command == command && visit.search.isRepeat && !visit.canAdd)
        #expect(visit.add(runner: runner) == nil)
        #expect(await adds() == [command] && visit.status == "Added jira-cli (2.1.0)")
    }

    /// A package that was in the lock before the visit, and the added one once the selection came back to it, add
    /// as before: the CLI resolves the entry again and keeps its constraint.
    @Test(.timeLimit(.minutes(1))) func anInstalledPackageIsAddedAgainOnceTheSelectionMoved() async throws {
        let visit = visit()
        visit.search.preload(
            query: "jira", results: .loaded(DesignFixtures.jiraSearch), selection: AddSkillTests.jira,
            info: AddSkillSamples.jiraInfo)
        #expect(visit.canAdd, "installed before the visit")
        let command = try await add(Self.cli, in: visit, installed: [Self.cli])
        await client.json(
            .info(.package(Self.markdown.package)), in: scope, Self.info(Self.markdown))
        visit.search.selection = Self.markdown.package
        await visit.search.infoTask?.value
        #expect(visit.canAdd)
        await client.json(.info(.package(Self.cli.package)), in: scope, Self.info(Self.cli))
        visit.search.selection = Self.cli.package
        #expect(visit.search.preview == .loading, "the preview from before the add is read again")
        await visit.search.infoTask?.value
        #expect(visit.search.command == command && !visit.search.isRepeat && visit.canAdd)
    }

    @Test(.timeLimit(.minutes(1))) func anotherSkillOfTheAddedPackageCanFollow() async throws {
        let visit = visit(capabilities: Self.capable)
        await select(Self.cli, in: visit, skills: ["jira-cli", "jira-boards"])
        visit.search.excludedSkills = ["jira-boards"]
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#])
        await scriptRefresh([Self.cli])
        await visit.add(runner: runner)?.value
        #expect(!visit.canAdd)
        visit.search.excludedSkills = ["jira-cli"]
        #expect(visit.canAdd, "a different choice is a different add")
    }

    /// With `add --rename` the clash stays after the add (the other package still has the name), so the command,
    /// rename included, is the same once the scope refreshed: still the repeat.
    @Test(.timeLimit(.minutes(1))) func aRenamedAddIsNotRepeatedAfterTheRefresh() async throws {
        let visit = visit(capabilities: Self.capable)
        visit.search.preload(
            query: AddSkillSamples.kolyaPackage, selection: AddSkillSamples.kolyaPackage,
            info: AddSkillSamples.kolyaInfo)
        #expect(visit.search.clash?.suggestion == "kolya-pdf")
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added kolya/pdf-tools = "^1.0" (1.0.0)"#])
        await scriptRefresh([
            Added(package: "anthropics/skills", skill: "pdf", version: "1.4.0"),
            Added(package: AddSkillSamples.kolyaPackage, skill: "kolya-pdf", version: "1.0.0"),
        ])
        await visit.add(runner: runner)?.value
        #expect(visit.status == "Added kolya-pdf (1.0.0)")
        #expect(visit.search.store.snapshot?.entries.map(\.name) == ["pdf", "kolya-pdf"], "refreshed")
        #expect(visit.search.command == command && visit.search.isRepeat && !visit.canAdd)
        visit.search.renameTo = "pdf-tools"
        #expect(visit.canAdd, "another name is another add")
    }

    // MARK: - Preview after an add

    func infoReads() async -> Int {
        await client.commands.filter { if case .info = $0 { true } else { false } }.count
    }

    /// The added row keeps the preview it had, and nothing is read that the user did not ask for: not for the
    /// added row, and not for a row the selection moved to while the scope was still refreshing.
    @Test(.timeLimit(.minutes(1))) func nothingIsReadAgainUnaskedAfterAnAdd() async throws {
        let visit = visit()
        await select(Self.markdown, in: visit)
        await select(Self.cli, in: visit)
        let preview = visit.search.preview
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#])
        let refresh = Gate()
        await client.json(.status, in: scope, Self.status([Self.cli]), gate: refresh)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let task = visit.add(runner: runner)
        await refresh.arrived()
        #expect(visit.added.count == 1 && visit.search.preview == preview, "the run ended; the refresh is reading")
        visit.search.selection = Self.markdown.package
        await refresh.open()
        await task?.value
        #expect(await infoReads() == 2, "the two previews the user opened")
        #expect(visit.search.info?.package == Self.markdown.package && visit.canAdd)
    }

    /// The next add may start while the scope still refreshes after the last one.
    @Test(.timeLimit(.minutes(1))) func theNextAddMayStartWhileTheScopeRefreshes() async throws {
        let visit = visit()
        await select(Self.cli, in: visit)
        let first = try #require(visit.search.command)
        await client.lines(first, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#])
        let refresh = Gate()
        await client.json(.status, in: scope, Self.status([Self.cli]), gate: refresh)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let firstTask = visit.add(runner: runner)
        await refresh.arrived()
        await select(Self.markdown, in: visit)
        let second = try #require(visit.search.command)
        await client.lines(second, in: scope, [#"added kolya/jira-to-md = "^0.9" (0.9.0)"#])
        await scriptRefresh([Self.cli, Self.markdown])
        let secondTask = visit.add(runner: runner)
        #expect(secondTask != nil && visit.run.isRunning)
        await refresh.open()
        await firstTask?.value
        await secondTask?.value
        #expect(await adds() == [first, second] && visit.status == "Added jira-to-md (0.9.0) · 2 skills added")
        #expect(visit.search.isRepeat && !visit.canAdd, "the guard is the second add's")
        #expect(await infoReads() == 2)
    }

    /// The guard compares what was chosen, not the command built from it: the command also reads `info`, and for a
    /// locked package `info` answers with the lock's version (a commit for a branch), which builds another command.
    @Test(.timeLimit(.minutes(1))) func theRepeatGuardHoldsWhenThePreviewAnswersDifferently() async throws {
        let source = "github:acme/jira"
        let visit = visit()
        visit.search.preload(
            query: source, selection: source,
            info: DesignFixtures.decode(
                InfoDocument.self, json: #"{"package":"acme/jira","version":"1.2.0","skills":[{"name":"jira"}]}"#))
        visit.search.rule = .branch("")
        visit.search.branch = "main"
        let command = try #require(visit.search.command)
        #expect(command == .add(spec: "\(source)@main", repository: nil, adopt: false, rename: [:], skills: []))
        await client.lines(command, in: scope, [#"added acme/jira = "main" (3f2a9c1d0b7e)"#])
        await scriptRefresh([])
        await visit.add(runner: runner)?.value
        visit.search.preload(
            query: source, selection: source,
            info: DesignFixtures.decode(
                InfoDocument.self,
                json: #"{"package":"acme/jira","version":"3f2a9c1d0b7e","locked":true,"skills":[{"name":"jira"}]}"#))
        #expect(visit.search.command != command, "no version to build the rule from")
        #expect(visit.search.isRepeat && !visit.canAdd)
        visit.search.branch = "dev"
        #expect(!visit.search.isRepeat, "another branch is another add")
    }

    /// The cache is per row, and two rows can be one package (skills.sh lists `github:owner/repo/<skill>`): the
    /// other row's preview predates the add as well.
    @Test(.timeLimit(.minutes(1))) func anotherRowOfTheAddedPackageIsReadAgainToo() async throws {
        let pdf = "github:acme/office/pdf"
        let docx = "github:acme/office/docx"
        let document = #"{"package":"acme/office","skills":[{"name":"pdf"},{"name":"docx"}]}"#
        let visit = visit()
        visit.search.sourceFilter = nil
        visit.search.preload(
            query: "pdf",
            results: .loaded(
                DesignFixtures.decode(
                    SearchDocument.self,
                    json: #"{"results":[{"name":"\#(pdf)","source":"skills.sh"},"#
                        + #"{"name":"\#(docx)","source":"skills.sh"}],"skills-sh":true}"#)))
        for row in [docx, pdf] {
            await client.json(.info(.package("github:acme/office")), in: scope, document)
            visit.search.selection = row
            await visit.search.infoTask?.value
        }
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added acme/office = "main" (3f2a9c1d0b7e)"#])
        await scriptRefresh([])
        await visit.add(runner: runner)?.value
        await client.json(.info(.package("github:acme/office")), in: scope, document)
        visit.search.selection = docx
        #expect(visit.search.preview == .loading, "not the preview from before the add")
        await visit.search.infoTask?.value
        #expect(visit.search.info != nil)
    }

    // MARK: - Skills of one package

    static let alpha = Added(package: "acme/tools", skill: "alpha", version: "3f2a9c1d0b7e")
    static let beta = Added(package: "acme/tools", skill: "beta", version: "3f2a9c1d0b7e")
    static let alphaRow = "github:acme/tools/alpha"
    static let betaRow = "github:acme/tools/beta"

    /// A visit whose results are two skills of one repository, as skills.sh lists them, and the whole repository.
    func toolsVisit(capabilities: Capabilities = Capabilities(version: Capabilities.minimum)) -> AddSkillVisit {
        let visit = visit(capabilities: capabilities)
        visit.search.sourceFilter = nil
        let rows = [Self.alphaRow, Self.betaRow].map { #"{"name":"\#($0)","source":"skills.sh"}"# }
        visit.search.preload(
            query: "tools",
            results: .loaded(
                DesignFixtures.decode(
                    SearchDocument.self,
                    json: #"{"results":[\#(rows.joined(separator: ",")),"#
                        + #"{"name":"github:acme/tools","source":"github"}],"skills-sh":true}"#)))
        return visit
    }

    /// `info` of the repository: every skill before it is locked, afterwards the lock's skills only
    /// (`src/commands.rs` `info`: "The locked version's skills are the lock's"). `why` is the entry's line, or the
    /// requirer's for a package that is only a dependency.
    static func toolsInfo(
        locked: [String]?, source: String = "github", why: String = #"acme/tools: in skills.toml as \"main\""#
    ) -> String {
        let skills = (locked ?? ["alpha", "beta", "gamma"]).map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        let why = locked == nil ? "" : "\"\(why)\""
        return #"{"package":"acme/tools","source":"\#(source)","version":"3f2a9c1d0b7e","locked":\#(locked != nil),"#
            + #""skills":[\#(skills)],"versions":[],"why":[\#(why)]}"#
    }

    /// The `info` a row of the repository asks for: the entry's own (`acme/tools`) once the scope's snapshot has
    /// the package from skills.toml, the repository's (`github:acme/tools`) before.
    static let entryTarget = "acme/tools"
    static let repositoryTarget = "github:acme/tools"

    /// Selects a row of the repository and loads its preview; `locked` is what the lock selects by then.
    func selectTools(
        _ row: String, in visit: AddSkillVisit, locked: [String]?, source: String = "github",
        why: String = #"acme/tools: in skills.toml as \"main\""#, dependency: Bool = false
    ) async {
        let target = locked == nil || dependency ? Self.repositoryTarget : Self.entryTarget
        await client.json(
            .info(.package(target)), in: scope, Self.toolsInfo(locked: locked, source: source, why: why))
        visit.search.selection = row
        await visit.search.infoTask?.value
    }

    /// Reads the scope with `installed` in the lock, as it was before the sheet opened.
    func load(_ installed: [Added], in visit: AddSkillVisit) async {
        await scriptRefresh(installed)
        await visit.search.store.refresh()
    }

    /// Adds the selected row at exit 0; `installed` is what the lock holds afterwards.
    func addTools(in visit: AddSkillVisit, installed: [Added]) async throws {
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added acme/tools = "main" (3f2a9c1d0b7e)"#])
        await scriptRefresh(installed)
        await visit.add(runner: runner)?.value
    }

    func toolsRow(_ name: String, in visit: AddSkillVisit) throws -> SearchDocument.Result {
        try #require(visit.search.filteredResults.first { $0.name == name })
    }

    /// The marker is the skill's, not the package's: one added skill does not mark its package's other rows.
    @Test(.timeLimit(.minutes(1))) func onlyTheAddedSkillsRowReadsInstalled() async throws {
        let visit = toolsVisit()
        let (alpha, beta) = (try toolsRow(Self.alphaRow, in: visit), try toolsRow(Self.betaRow, in: visit))
        #expect(!visit.search.isInstalled(alpha) && !visit.search.isInstalled(beta))
        #expect(visit.search.otherInstalledSkills(of: beta).isEmpty)
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        try await addTools(in: visit, installed: [Self.alpha])
        #expect(visit.search.isInstalled(alpha) && visit.search.installedSkills(of: alpha) == ["alpha"])
        #expect(!visit.search.isInstalled(beta), "beta is not in the scope")
        #expect(visit.search.installedSkills(of: beta).isEmpty)
        #expect(visit.search.otherInstalledSkills(of: beta) == ["alpha"])
        #expect(visit.search.otherInstalledSkills(of: alpha).isEmpty, "an installed row says only that")
        let whole = try toolsRow("github:acme/tools", in: visit)
        #expect(visit.search.isInstalled(whole) && visit.search.installedSkills(of: whole) == ["alpha"])
        #expect(visit.search.otherInstalledSkills(of: whole).isEmpty, "a row for the whole package has no others")
    }

    /// After alpha, `info` lists the lock's skills only (alpha): beta's preview still names beta, says it joins
    /// alpha, and Add sends beta's own spec, which the CLI merges into the entry's `skills`.
    @Test(.timeLimit(.minutes(1))) func anotherSkillsRowPreviewsAndAddsThatSkill() async throws {
        let visit = toolsVisit()
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        #expect(visit.search.providedSkills.map(\.name) == ["alpha"])
        #expect(visit.search.skillsNote == "Only this skill is added, not the whole package.")
        try await addTools(in: visit, installed: [Self.alpha])
        await selectTools(Self.betaRow, in: visit, locked: ["alpha"])
        #expect(visit.search.providedSkills.map(\.name) == ["beta"], "not alpha, the one skill `info` lists")
        #expect(visit.search.chosenSkills == ["beta"])
        #expect(visit.search.skillsNote == "Only this skill is added, next to alpha from the same package.")
        #expect(
            visit.search.command
                == .add(spec: Self.betaRow, repository: nil, adopt: false, rename: [:], skills: []))
        #expect(!visit.search.isRepeat && visit.canAdd)
        #expect(visit.search.entryWarning == nil)
        #expect(await client.commands.contains(.info(.package(Self.entryTarget))), "the entry's own source is asked")
    }

    /// The scope may still be refreshing when the next row is selected: the repository's `info` is asked then, and
    /// the package this sheet added from GitHub is known to be a GitHub entry.
    @Test(.timeLimit(.minutes(1))) func aSkillSelectedBeforeTheRefreshStillJoinsTheAddedOne() async throws {
        let visit = toolsVisit()
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added acme/tools = "main" (3f2a9c1d0b7e)"#])
        let gate = Gate()
        await client.json(.status, in: scope, Self.status([Self.alpha]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let run = visit.add(runner: runner)
        await gate.arrived()
        await client.json(
            .info(.package(Self.repositoryTarget)), in: scope, Self.toolsInfo(locked: ["alpha"]))
        visit.search.selection = Self.betaRow
        await visit.search.infoTask?.value
        #expect(visit.search.skillsNote == "Only this skill is added, not the whole package.", "alpha not read yet")
        await gate.open()
        await run?.value
        #expect(visit.search.skillsNote == "Only this skill is added, next to alpha from the same package.")
        #expect(visit.search.entryWarning == nil)
    }

    /// `info` lists every skill of a package that is not locked: a skill it does not list is not invented.
    @Test(.timeLimit(.minutes(1))) func aSkillTheRepositoryDoesNotListIsNotInvented() async throws {
        let visit = toolsVisit()
        await selectTools("github:acme/tools/delta", in: visit, locked: nil)
        #expect(visit.search.info?.locked == false && visit.search.providedSkills.isEmpty)
        #expect(visit.search.chosenSkills == ["delta"], "the CLI stays the judge")
    }

    @Test(.timeLimit(.minutes(1))) func aSkillRowSaysItsLineWhereSkillsCanBeChosenToo() async throws {
        let visit = toolsVisit(capabilities: Self.capable)
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        #expect(visit.search.canChooseSkills)
        #expect(visit.search.skillsNote == "Only this skill is added, not the whole package.")
        await selectTools("github:acme/tools", in: visit, locked: nil)
        #expect(visit.search.skillsNote == nil, "the checkboxes say it")
    }

    // MARK: - A package of the same name from another source

    /// `add github:owner/repo[/skill]` merges only into a GitHub entry; an entry of that name from a registry is
    /// replaced, and its skills are removed (`src/commands.rs` `add_vcs`, which looks for GitHub entries only).
    /// `info github:…` reports `github` whatever the entry is, so the entry's own `info` is asked.
    @Test(.timeLimit(.minutes(1))) func aSkillOfAPackageFromAnotherSourceWarnsThatAddReplacesIt() async throws {
        let visit = toolsVisit()
        await load([Self.alpha], in: visit)
        let beta = try toolsRow(Self.betaRow, in: visit)
        #expect(!visit.search.isInstalled(beta) && visit.search.otherInstalledSkills(of: beta) == ["alpha"])
        let why = #"acme/tools: in skills.toml as \"^1.0\""#
        await selectTools(Self.betaRow, in: visit, locked: ["alpha"], source: "composer", why: why)
        #expect(await client.commands.last == .info(.package(Self.entryTarget)))
        #expect(visit.search.replacedSource == "composer")
        #expect(
            visit.search.entryWarning
                == UserMessage(
                    title: "acme/tools is already in this project from a Composer repository.",
                    reason: "Add replaces that entry with the GitHub repository and removes alpha.",
                    severity: .warning))
        #expect(visit.search.skillsNote == "Only this skill is added, not the whole package.", "no “next to alpha”")
        #expect(visit.search.providedSkills.map(\.name) == ["beta"])
        #expect(visit.search.existingConstraint == nil && visit.search.keptConstraint == nil, "^1.0 is not kept")
        #expect(visit.search.ruleBase == nil, "the version is the registry package's")
        #expect(
            visit.search.command
                == .add(spec: Self.betaRow, repository: nil, adopt: false, rename: [:], skills: []))
        #expect(visit.canAdd)

        await selectTools("github:acme/tools", in: visit, locked: ["alpha"], source: "composer", why: why)
        #expect(
            visit.search.entryWarning?.reason == "Add replaces that entry with the GitHub repository.",
            "which of its skills the repository has is not known")
        #expect(visit.search.providedSkills.isEmpty, "the lock's skills are the registry package's")
        #expect(visit.search.skillsNote == nil && visit.canAdd)

        await selectTools(Self.alphaRow, in: visit, locked: ["alpha"], source: "git", why: why)
        #expect(
            visit.search.entryWarning?.title == "acme/tools is already in this project from a git URL."
                && visit.search.entryWarning?.reason == "Add replaces that entry with the GitHub repository.")
    }

    @Test(.timeLimit(.minutes(1))) func theWarningGoesOnceTheAddReplacedTheEntry() async throws {
        let visit = toolsVisit()
        await load([Self.alpha], in: visit)
        await selectTools(
            Self.betaRow, in: visit, locked: ["alpha"], source: "composer",
            why: #"acme/tools: in skills.toml as \"^1.0\""#)
        try await addTools(in: visit, installed: [Self.beta])
        #expect(visit.search.entryWarning == nil && visit.status == "Added beta (3f2a9c1d0b7e)")
        #expect(visit.search.providedSkills.map(\.name) == ["beta"])
    }

    /// A package that is only a dependency has no skills.toml entry for `add` to merge into: nothing is promised
    /// about the skill a requirer brought.
    @Test(.timeLimit(.minutes(1))) func aSkillOfADependencyPromisesNoNeighbour() async throws {
        let visit = toolsVisit()
        let status =
            #"{"ok":true,"entries":[{"package":"acme/tools","skill":"alpha","version":"1.0.0","state":"ok","#
            + #""ok":true,"via":["acme/req"]}],"policy":{},"repositories":[]}"#
        await client.json(.status, in: scope, status)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await visit.search.store.refresh()
        await selectTools(
            Self.betaRow, in: visit, locked: ["alpha"], why: "acme/tools: required by acme/req (^1.0)",
            dependency: true)
        #expect(await client.commands.last == .info(.package(Self.repositoryTarget)), "no entry to ask about")
        #expect(visit.search.skillsNote == "Only this skill is added, not the whole package.")
        #expect(visit.search.entryWarning == nil && visit.canAdd)
    }

    // MARK: - An add that added nothing new

    static let renamed = Added(package: "acme/tools", skill: "acme-alpha", version: "3f2a9c1d0b7e")

    /// skills.toml renames alpha (`rename = { alpha = "acme-alpha" }`): `status` knows only the new name, so the
    /// row for alpha is not Installed and its add changes nothing. The visit claims no skill the scope lacks.
    @Test(.timeLimit(.minutes(1))) func anAddWhoseSkillIsNotInTheScopeClaimsNoSkill() async throws {
        let visit = toolsVisit()
        await load([Self.renamed], in: visit)
        await selectTools(Self.alphaRow, in: visit, locked: ["acme-alpha"])
        try await addTools(in: visit, installed: [Self.renamed])
        #expect(visit.status == "Added acme/tools" && visit.skillCount == 0)
        #expect(visit.footer == .added(text: "Added acme/tools", emphasis: [], count: nil))
        #expect(visit.cancelOrClose(runner: runner) == nil, "no skill to select")
        #expect(runner.toast?.text == "Added acme/tools" && visit.search.store.selection == nil)
    }

    @Test(.timeLimit(.minutes(1))) func anAddOfNothingNewIsNotCounted() async throws {
        let visit = toolsVisit()
        await load([Self.renamed], in: visit)
        await selectTools(Self.betaRow, in: visit, locked: ["acme-alpha"])
        try await addTools(in: visit, installed: [Self.renamed, Self.beta])
        await selectTools(Self.alphaRow, in: visit, locked: ["acme-alpha", "beta"])
        try await addTools(in: visit, installed: [Self.renamed, Self.beta])
        #expect(visit.status == "Added acme/tools · 1 skill added" && visit.skillCount == 1)
        await visit.cancelOrClose(runner: runner)?.value
        #expect(runner.toast?.text == "Added 1 skill to add-visit-tests")
        #expect(visit.search.store.selection == nil, "the last add named no skill of the scope")
    }

    /// A refresh that failed says nothing about what the add did: its words stand.
    @Test(.timeLimit(.minutes(1))) func aFailedRefreshLeavesTheAddsWords() async throws {
        let visit = toolsVisit()
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added acme/tools = "main" (3f2a9c1d0b7e)"#])
        await client.script(.status, in: scope, .error(.noDocument))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await visit.add(runner: runner)?.value
        #expect(visit.search.store.refreshError != nil)
        #expect(visit.status == "Added alpha (3f2a9c1d0b7e)" && visit.skillCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func twoSkillsOfOnePackageAreTwoAdds() async throws {
        let visit = toolsVisit()
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        try await addTools(in: visit, installed: [Self.alpha])
        #expect(visit.status == "Added alpha (3f2a9c1d0b7e)" && !visit.canAdd)
        await selectTools(Self.betaRow, in: visit, locked: ["alpha"])
        try await addTools(in: visit, installed: [Self.alpha, Self.beta])
        #expect(visit.search.skillsNote == "Adding it again keeps this package’s current skills.", "beta is there")
        #expect(
            await adds()
                == [Self.alphaRow, Self.betaRow]
                .map {
                    .add(spec: $0, repository: nil, adopt: false, rename: [:], skills: [])
                })
        let (alpha, beta) = (try toolsRow(Self.alphaRow, in: visit), try toolsRow(Self.betaRow, in: visit))
        #expect(visit.search.isInstalled(alpha) && visit.search.isInstalled(beta))
        #expect(visit.search.installedSkills(of: beta) == ["beta"])
        #expect(visit.search.otherInstalledSkills(of: beta).isEmpty)
        #expect(visit.status == "Added beta (3f2a9c1d0b7e) · 2 skills added" && visit.skillCount == 2)
        #expect(
            visit.footer == .added(text: "Added beta (3f2a9c1d0b7e)", emphasis: ["beta"], count: "· 2 skills added"))
        #expect(visit.search.isRepeat && !visit.canAdd, "beta was just added")
        await selectTools(Self.alphaRow, in: visit, locked: ["alpha", "beta"])
        #expect(!visit.search.isRepeat && visit.canAdd, "alpha is another add than beta")
        #expect(
            visit.search.skillsNote == "Adding it again keeps this package’s current skills.",
            "alpha is there: nothing is added next to beta")
        visit.cancelOrClose(runner: runner)
        #expect(runner.toast?.text == "Added 2 skills to add-visit-tests")
    }

    /// A row for the whole package adds what `info` lists; once the package has an entry, `add` keeps that
    /// entry's skills (`src/commands.rs` `add_vcs`), so the line under the list no longer promises every skill.
    @Test(.timeLimit(.minutes(1))) func aWholePackageRowSaysWhatAddKeeps() async throws {
        let visit = toolsVisit()
        await selectTools("github:acme/tools", in: visit, locked: nil)
        #expect(visit.search.providedSkills.map(\.name) == ["alpha", "beta", "gamma"])
        #expect(visit.search.skillsNote == "This version of skillcask adds every skill in the package.")
        await selectTools(Self.alphaRow, in: visit, locked: nil)
        try await addTools(in: visit, installed: [Self.alpha])
        await selectTools("github:acme/tools", in: visit, locked: ["alpha"])
        #expect(visit.search.providedSkills.map(\.name) == ["alpha"])
        #expect(visit.search.skillsNote == "Adding it again keeps this package’s current skills.")
        #expect(visit.canAdd)
    }

    @Test func theRowSaysWhichSkillsOfItsPackageAreThere() {
        let row = "github:Acme/tools/beta"
        #expect(
            ResultRow.note(for: row, installedAs: ["alpha"], otherSkills: [], isPersonal: false)
                == "Already in this project as alpha.")
        #expect(
            ResultRow.note(for: row, installedAs: [], otherSkills: ["alpha"], isPersonal: false)
                == "This project already has alpha from acme/tools.")
        #expect(
            ResultRow.note(for: row, installedAs: [], otherSkills: ["alpha", "gamma"], isPersonal: true)
                == "My Skills already has alpha and gamma from acme/tools.")
        #expect(
            ResultRow.note(for: row, installedAs: [], otherSkills: ["a", "b", "c"], isPersonal: false)
                == "This project already has a, b and c from acme/tools.")
        #expect(
            ResultRow.note(for: row, installedAs: [], otherSkills: ["a", "b", "c", "d", "e"], isPersonal: false)
                == "This project already has a, b and 3 more from acme/tools.", "two lines hold it")
        #expect(ResultRow.note(for: row, installedAs: [], otherSkills: [], isPersonal: false) == nil)
        #expect(
            AddSkillCopy.oneSkillAdded(alongside: ["a", "b", "c", "d"])
                == "Only this skill is added, next to a, b and 2 more from the same package.")
    }

    // MARK: - Copy

    @Test func theFooterAndTheClosingToastCountSkills() {
        #expect(AddSkillCopy.status("Added pdf (1.4.0)", count: nil) == "Added pdf (1.4.0)")
        #expect(AddSkillCopy.addedSoFar(3) == "· 3 skills added" && AddSkillCopy.addedSoFar(1) == "· 1 skill added")
        #expect(
            AddSkillCopy.status("Added pdf (1.4.0)", count: AddSkillCopy.addedSoFar(3))
                == "Added pdf (1.4.0) · 3 skills added")
        #expect(AddSkillCopy.summary(done: 3, scope: "api") == "Added 3 skills to api")
        #expect(AddSkillCopy.summary(done: 1, scope: "My Skills") == "Added 1 skill to My Skills")
        #expect(AddSkillCopy.done == "Done")
    }

    /// Two skills of one package count as two; the same package added twice counts once.
    @Test(.timeLimit(.minutes(1))) func theCountIsOfSkillsNotOfRuns() async throws {
        let visit = visit()
        let boards = Added(package: Self.cli.package, skill: "jira-boards", version: Self.cli.version)
        await select(Self.cli, in: visit, skills: ["jira-cli", "jira-boards"])
        let command = try #require(visit.search.command)
        await client.lines(command, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#])
        await scriptRefresh([Self.cli, boards])
        await visit.add(runner: runner)?.value
        #expect(visit.status == "Added jira-cli and jira-boards (2.1.0)" && visit.skillCount == 2)
        try await add(Self.markdown, in: visit, installed: [Self.cli, boards, Self.markdown])
        #expect(visit.status == "Added jira-to-md (0.9.0) · 3 skills added")
        await client.json(
            .info(.package(Self.cli.package)), in: scope, Self.info(Self.cli, skills: ["jira-cli", "jira-boards"]))
        visit.search.selection = Self.cli.package
        await visit.search.infoTask?.value
        await client.lines(command, in: scope, [#"added atlassian/jira-cli-skill = "^2.1" (2.1.0)"#])
        await scriptRefresh([Self.cli, boards, Self.markdown])
        await visit.add(runner: runner)?.value
        #expect(visit.status == "Added jira-cli and jira-boards (2.1.0) · 3 skills added")
    }
}
