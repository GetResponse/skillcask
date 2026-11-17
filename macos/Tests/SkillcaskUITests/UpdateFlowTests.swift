import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The F3 flow walk (Update with review): a cooldown is never an update, the sheet's failure discloses its
/// transcript in place, the sheet closes at exit 0 while the refresh runs behind it, the selected detail reloads,
/// and the fetching state names the version.
@Suite @MainActor struct UpdateFlowTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/update-flow-tests"))
    /// jira-communication's 4.3.0 is eligible at `2026-10-30T09:14:00Z` (the design fixtures' cooldown note).
    static let jiraEligible = Date(timeIntervalSince1970: 1_793_351_640)
    let update = Invocation.Command.update(packages: ["anthropics/skills"])

    func scopeStore(_ snapshot: ScopeSnapshot = DesignFixtures.api) -> ScopeStore {
        let store = ScopeStore(scope: scope, client: client, capabilities: Capabilities(version: Capabilities.minimum))
        {
            _ in SkillText.parse("# fake")
        }
        store.preload(snapshot: snapshot)
        return store
    }

    func scriptRefresh(gate: Gate? = nil) async {
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.4.0")]), gate: gate)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
    }

    // MARK: - Cooldown truth

    @Test func aWithinThatWaitsIsACooldownEverywhere() throws {
        let api = DesignFixtures.api
        let jira = try #require(api.entry(id: "jira-communication"))
        #expect(jira.health == .cooldown(until: "4.3.0 eligible 2026-10-30T09:14:00Z"))
        #expect(!jira.hasUpdate)
        #expect(Labels.health(jira.health, timeZone: .gmt) == "4.3.0 on 30 Oct")
        #expect(api.availableUpdates.map(\.package) == ["acme/review-pr", "anthropics/skills"], "Update All 2")
        #expect(UpdatesCard.cooldowns(api).map(\.package) == ["netresearch/agent-jira-skill"])
        #expect(UpdatesCard.outside(api).map(\.package) == ["acme/lint"])
        #expect(UpdatesCard.rows(api).allSatisfy { $0.package != "netresearch/agent-jira-skill" })
        let model = VersionsModel(entry: jira, policy: api.policy, allowedRange: "^4.2")
        #expect(model.status == .cooldown(try #require(model.cooldown)) && model.inRangeVersion == "4.3.0")
    }

    @Test func aReviewOfAWaitingPackageSaysWhyNothingIsUpdated() async {
        await client.json(
            .diff(package: "netresearch/agent-jira-skill"), in: scope, DesignFixtures.text("diff.up-to-date", "txt"))
        let review = ReviewStore(package: "jira-communication", store: scopeStore())
        await review.load()
        #expect(review.isUpToDate)
        #expect(review.waiting.map(\.version) == ["4.3.0"])
        // One package: its own sentence with the eligible date, no sibling names ("not included" is Update All's).
        // The store writes the date in the Mac's zone (30 Oct 2026 in GMT).
        let eligible = Formatters.dayMonthYear(Self.jiraEligible)
        #expect(
            review.upToDateBody
                == "4.2.0 is installed and matches skills.lock. 4.3.0 is inside your range but waits for the minimum "
                + "release age until \(eligible).")
        let other = ReviewStore(package: "anthropics/skills", store: scopeStore())
        #expect(other.waiting.isEmpty, "a single review notes only its own package")
    }

    // MARK: - Fetching

    @Test func theFetchingLineNamesTheVersion() {
        let offered = ReviewStore(package: "anthropics/skills", offeredVersion: "1.4.0", store: scopeStore())
        #expect(offered.fetchingText == "Fetching changes for 1.4.0…")
        #expect(ReviewStore(package: "pdf", store: scopeStore()).fetchingText == "Fetching changes for pdf…")
        #expect(ReviewStore(package: nil, store: scopeStore()).fetchingText == "Fetching changes…")
    }

    // MARK: - Done state

    @Test(.timeLimit(.minutes(1))) func exitZeroClosesTheSheetWhileTheRefreshRunsBehindIt() async {
        // The CLI's report line (`src/commands.rs` `update`): without it the toast says pdf was not updated.
        await client.lines(
            update, in: scope, ["Updating pdf 1.2.0 → 1.4.0 (github)…", "updated anthropics/skills 1.2.0 -> 1.4.0"])
        let slow = Gate()
        await scriptRefresh(gate: slow)
        let store = scopeStore()
        let review = ReviewStore(package: "anthropics/skills", store: store)
        review.preload(DesignFixtures.pdfDiff)
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        let task = review.update(with: run, in: store, runner: runner) { closed = true }
        await slow.arrived()
        #expect(closed && run.phase == .succeeded, "the sheet closed before the refresh answered")
        #expect(runner.toast?.text == "Updated pdf to 1.4.0" && runner.current == nil)
        #expect(store.isRefreshing, "the list header carries the refresh (S11)")
        #expect(ListState.resolve(store: store, running: runner.current).progressTitle == ListCopy.checking)
        await slow.open()
        await task?.value
        #expect(!store.isRefreshing && run.phase == .succeeded)
    }

    @Test(.timeLimit(.minutes(1))) func theProgressNeverOutlivesTheRunnersAction() async {
        let gate = Gate()
        await client.lines(update, in: scope, ["Resolving anthropics/skills (^1.2)… 1.4.0"], exit: 1, gate: gate)
        let slow = Gate()
        await scriptRefresh(gate: slow)
        let store = scopeStore()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        let task = run.start(
            update, title: "Updating pdf to 1.4.0…", outcome: { $0 }, in: store, runner: runner, onSuccess: {})
        await gate.arrived()
        #expect(run.isRunning && run.action != nil)
        await gate.open()
        await slow.arrived()
        #expect(!run.isRunning && run.action == nil && run.failure != nil, "ended with the run, not after the refresh")
        await slow.open()
        await task?.value
    }

    // MARK: - Failure details

    @Test(.timeLimit(.minutes(1))) func anIntegrityFailureKeepsItsTranscriptInTheSheetAndNoRetry() async throws {
        await client.lines(
            update, in: scope, ["Downloading 1.4.0 (github)… 142 KB", "Verifying content hash… mismatch"], exit: 4)
        await scriptRefresh()
        let store = scopeStore()
        let review = ReviewStore(package: "anthropics/skills", store: store)
        review.preload(DesignFixtures.pdfDiff)
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        await review.update(with: run, in: store, runner: runner) { closed = true }?.value
        let failure = try #require(run.failure)
        #expect(!closed && failure.isIntegrity && !FailureBanner.showsRetry(failure))
        let entry = try #require(run.failedEntry)
        #expect(entry.id == run.runID && runner.activity.first?.id == entry.id, "the run stays in Activity")
        let lines = ActivityCopy.transcriptLines(of: entry)
        #expect(lines.contains("Verifying content hash… mismatch"))
        #expect(ActivityCopy.copyText(of: entry).contains("skillcask"), "Copy starts with the command")
        #expect(runner.banner == nil, "the window's banner stays the window's")
    }

    @Test func aRefusalHasNoTranscript() {
        let runner = ActionRunner(queue: MutationQueue())
        runner.preloadRunning(title: "Syncing…", in: scope)
        let run = SheetRun()
        let task = run.start(
            update, title: "Updating pdf…", outcome: { $0 }, in: scopeStore(), runner: runner, onSuccess: {})
        #expect(task == nil && run.failure != nil && run.failedEntry == nil)
    }

    // MARK: - Detail after the update

    @Test(.timeLimit(.minutes(1))) func theSelectedDetailReloadsAfterAMutation() async {
        let info = #"{"skill":"pdf","kind":"package","path":"x","from":"y"}"#
        await client.json(.info(.skill("pdf")), in: scope, info)
        await client.json(.info(.skill("pdf")), in: scope, info)
        await scriptRefresh()
        let store = ScopeStore(scope: scope, client: client, capabilities: Capabilities(version: Capabilities.minimum))
        {
            _ in SkillText.parse("# fake")
        }
        store.preload(snapshot: DesignFixtures.api)
        await store.select("pdf")
        #expect(await client.commands.filter { $0 == .info(.skill("pdf")) }.count == 1)
        store.preload(snapshot: DesignFixtures.api, selection: "pdf", detail: store.detail)
        await store.refreshAfterMutation()
        #expect(store.selection == "pdf" && store.selectedEntry?.version == "1.4.0")
        #expect(await client.commands.filter { $0 == .info(.skill("pdf")) }.count == 2, "info read again")
        #expect(store.detail != nil)
    }

    // MARK: - Review fixes

    @Test(.timeLimit(.minutes(1))) func aRetryDuringThePreviousRefreshIsNotEndedByIt() async {
        // First Update fails; its refresh is held. Retry starts meanwhile and must survive the first task's end.
        await client.lines(update, in: scope, ["Resolving anthropics/skills (^1.2)… 1.4.0"], exit: 1)
        let retryGate = Gate()
        await client.lines(update, in: scope, ["Writing skills.lock"], gate: retryGate)
        let slow = Gate()
        await scriptRefresh(gate: slow)
        await scriptRefresh()
        let store = scopeStore()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        let first = run.start(
            update, title: "Updating pdf…", outcome: { $0 }, in: store, runner: runner, onSuccess: { closed = true })
        await slow.arrived()
        #expect(run.failure != nil && !closed)
        let retry = run.start(
            update, title: "Updating pdf…", outcome: { _ in "Updated pdf" }, in: store, runner: runner,
            onSuccess: { closed = true })
        #expect(retry != nil)
        await retryGate.arrived()
        await slow.open()
        await first?.value
        #expect(run.isRunning && run.action != nil && run.failure == nil, "the old start's end left the retry alone")
        await retryGate.open()
        await retry?.value
        #expect(closed && run.phase == .succeeded, "the retry's own success closes the sheet")
    }

    @Test func afterAnIntegrityFailureUpdateIsNeitherDefaultNorEnabled() {
        let review = ReviewStore(package: "anthropics/skills", store: scopeStore())
        review.preload(DesignFixtures.pdfDiff)
        let integrity = ErrorCopy.message(
            for: .failed(code: .integrity, message: "content did not match the lock", hint: nil, stderr: ""),
            title: "Couldn’t update pdf.")
        let network = ErrorCopy.message(
            for: .failed(code: .network, message: "no route", hint: nil, stderr: ""), title: "Couldn’t update pdf.")
        #expect(integrity.isIntegrity)
        #expect(
            review.primaryButton(isRunning: false, failure: integrity) == .update(isDefault: false, isEnabled: false))
        #expect(review.primaryButton(isRunning: false, failure: network) == .update(isDefault: true, isEnabled: true))
    }

    @Test func anOfferDiffDoesNotReachIsNotCalledNothingNewer() async {
        // A GitHub row: `outdated` offered 1.4.0 (no cooldown note there), `diff` locks nothing newer now.
        await client.json(.diff(package: "anthropics/skills"), in: scope, DesignFixtures.text("diff.up-to-date", "txt"))
        let review = ReviewStore(package: "pdf", offeredVersion: "1.4.0", store: scopeStore())
        await review.load()
        #expect(review.isUpToDate && review.offeredButNothingToLock == "1.4.0")
        #expect(
            review.upToDateBody
                == "1.2.0 is installed and matches skills.lock. The command-line tool has nothing newer to lock now; "
                + "1.4.0 may still be inside the minimum release age.")
        #expect(!review.upToDateBody.contains("Nothing newer exists"))
    }

    @Test func readTheChangesOfACooldownReadsTheWaitingVersionReviewOnly() async throws {
        let jira = try #require(DesignFixtures.api.entry(id: "jira-communication"))
        let sheet = AppStore.Sheet.readChanges(of: jira)
        #expect(sheet == .update(package: "netresearch/agent-jira-skill", target: "4.3.0", reviewOnly: true))
        let pdf = try #require(DesignFixtures.api.entry(id: "pdf"))
        #expect(AppStore.Sheet.readChanges(of: pdf) == .update(for: pdf), "an update in range reviews as before")
        let waiting = Invocation.Command.diffTo(package: "netresearch/agent-jira-skill", version: "4.3.0")
        await client.json(waiting, in: scope, DesignFixtures.text("diff.jira-communication", "txt"))
        let review = ReviewStore(
            package: "netresearch/agent-jira-skill", offeredVersion: "4.3.0", reviewOnly: true, store: scopeStore())
        #expect(review.readsWaitingVersion?.version == "4.3.0" && review.isReviewOnly)
        await review.load()
        #expect(await client.commands == [waiting], "diff --to, cooldown not applied")
        #expect(review.packages.first?.to == "4.3.0")
        #expect(review.primaryButton(isRunning: false) == .done, "update would not lock it yet")
        #expect(review.isDoneAlone && review.titleWords == "Changes in jira-communication 4.3.0")
        #expect(review.versions == nil, "a review title, not \"Update … 4.2.0 → 4.3.0\"")
        // The Mac's zone, as the store writes it (30 Oct 2026 in GMT).
        let eligible = Formatters.dayMonthYear(Self.jiraEligible)
        #expect(review.footnote == "Update can lock 4.3.0 from \(eligible), once it is past the minimum release age.")
    }

    @Test func theCooldownNeverSaysNothingToDo() throws {
        let jira = try #require(DesignFixtures.api.entry(id: "jira-communication"))
        let model = VersionsModel(entry: jira, policy: DesignFixtures.api.policy, allowedRange: "^4.2")
        let body = VersionsCopy.cooldownBody(minimumAge: model.minimumAge, released: nil)
        #expect(!body.contains("nothing to do"))
        #expect(body.hasSuffix("Review changes… on the Overview shows what Update would lock."))
    }

    @Test func aNoteOnlyOutdatedParsesEndToEnd() throws {
        // The 0.9.4 shape: no `eligible` or release-time keys, the cooldown only in the note.
        let snapshot = DesignFixtures.apiNoteOnly
        let jira = try #require(snapshot.entry(id: "jira-communication"))
        #expect(jira.health == .cooldown(until: "4.3.0 eligible 2026-10-30T09:14:00Z"))
        #expect(jira.update?.eligible == DesignFixtures.date("2026-10-30T09:14:00Z") && jira.update?.released == nil)
        #expect(jira.released == nil && jira.update?.withinReleased == nil && jira.update?.lockedReleased == nil)
        #expect(snapshot.availableUpdates.map(\.package) == ["acme/review-pr", "anthropics/skills"])
    }
}
