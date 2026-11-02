import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// S11 and S12 (Running, Health-States boards): the list dims only for a window run in its own scope, the header
/// grows into the long-run block after its threshold, an integrity failure is never retried and keeps its banner
/// beside a later toast, the toast's and the banner's details name the run, and the Health popover groups
/// `doctor`'s answer as the board does.
@Suite @MainActor struct RunningTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/running-tests"))
    let other = Scope.project(URL(fileURLWithPath: "/tmp/running-tests-other"))
    let capabilities = Capabilities(version: Capabilities.minimum)

    func store(_ scope: Scope? = nil) -> ScopeStore {
        let store = ScopeStore(scope: scope ?? self.scope, client: client, capabilities: capabilities) { _ in
            SkillText.parse("")
        }
        store.preload(snapshot: DesignFixtures.api)
        return store
    }

    // MARK: - Dimming

    @Test func aWindowRunInTheScopeDimsTheList() {
        let store = store()
        let runner = ActionRunner(queue: MutationQueue())
        runner.preloadRunning(title: ActionCopy.syncing, in: scope)
        let state = ListState.resolve(store: store, running: runner.current)
        #expect(state.isRunning && state.isDimmed)
        #expect(state.progressTitle == "Syncing with skills.lock…")
        #expect(state.rows.count == 14, "the rows stay while dimmed")
    }

    @Test func aSheetRunDoesNotDimTheList() {
        let store = store()
        let runner = ActionRunner(queue: MutationQueue())
        runner.preloadRunning(title: ActionCopy.syncing, in: scope, from: .sheet)
        let state = ListState.resolve(store: store, running: runner.current)
        #expect(!state.isRunning && !state.isDimmed && state.progressTitle == nil)
    }

    @Test func aRunInAnotherScopeDoesNotDimTheList() {
        let store = store()
        let runner = ActionRunner(queue: MutationQueue())
        runner.preloadRunning(title: ActionCopy.syncing, in: other)
        let state = ListState.resolve(store: store, running: runner.current)
        #expect(!state.isRunning && !state.isDimmed && state.progressTitle == nil)
    }

    @Test func refreshingDimsWithoutARun() {
        let state = ListState.resolve(
            snapshot: DesignFixtures.api, filter: .all, query: "", sort: .state, isOffline: false, isRefreshing: true)
        #expect(state.isDimmed && !state.isRunning)
        let idle = ListState.resolve(
            snapshot: DesignFixtures.api, filter: .all, query: "", sort: .state, isOffline: false, isRefreshing: false)
        #expect(!idle.isDimmed)
    }

    // MARK: - Long run

    @Test(arguments: [(0.0, RunProgress.Phase.bar), (1.9, .bar), (2.0, .block), (3.2, .block), (600, .block)])
    func theBlockAppearsAfterTheThreshold(elapsed: TimeInterval, phase: RunProgress.Phase) {
        #expect(RunProgress.phase(elapsed: elapsed) == phase)
    }

    @Test(arguments: [(0.0, "0:00"), (3.2, "0:03"), (59.9, "0:59"), (75, "1:15"), (-1, "0:00"), (3600, "60:00")])
    func elapsedIsMinutesAndSeconds(seconds: TimeInterval, text: String) {
        #expect(RunningCopy.elapsed(seconds) == text)
    }

    @Test func theBlockKeepsTheNewestTwoLines() {
        let lines: [OutputLine] = [.stdout("one"), .stderr("two"), .stdout("  "), .stdout("three")]
        #expect(RunProgress.tail(lines) == ["two", "three"])
        #expect(RunProgress.tail([]).isEmpty)
    }

    @Test func theBlockReadsTheRunningAction() {
        let runner = ActionRunner(queue: MutationQueue())
        let started = Date(timeIntervalSinceNow: -3)
        runner.preloadRunning(title: ActionCopy.syncing, in: scope, startedAt: started, lines: [.stdout("a")])
        guard let current = runner.current else {
            Issue.record("no running action")
            return
        }
        let model = RunProgress.Model(current)
        #expect(model.title == ActionCopy.syncing && model.startedAt == started && model.lines == [.stdout("a")])
    }

    // MARK: - Integrity

    func failedSync(exit: Int32) async -> (ActionRunner, ScopeStore) {
        await client.lines(.install(frozen: false), in: scope, [], exit: exit)
        let store = store()
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store)
        return (runner, store)
    }

    @Test(.timeLimit(.minutes(1))) func anIntegrityFailureOffersNoRetryAndIsNeverRerun() async {
        let (runner, store) = await failedSync(exit: 4)
        guard let banner = runner.banner else {
            Issue.record("exit 4 left no banner")
            return
        }
        #expect(banner.isIntegrity)
        #expect(!FailureBanner.showsRetry(banner))
        #expect(FailureBanner.layout(for: banner, hasRetry: true, hasDetails: true) == .stacked)
        #expect(FailureBanner.symbol(for: banner) == FailureBanner.integritySymbol)
        #expect(runner.retry() == nil)
        #expect(await client.commands.filter { $0 == .install(frozen: false) }.count == 1)
        withExtendedLifetime(store) {}
    }

    @Test(.timeLimit(.minutes(1))) func theIntegrityBannerStaysBesideALaterToast() async {
        let (runner, store) = await failedSync(exit: 4)
        await client.json(.doctor(fix: false), in: scope, DesignFixtures.text("doctor.api", "json"), exit: 1)
        await runner.check(in: store)
        #expect(runner.toast?.text == ActionCopy.checked("running-tests"))
        #expect(runner.banner?.isIntegrity == true, "the integrity banner stays until dismissed")
        #expect(runner.retry() == nil)
        #expect(await client.commands.filter { $0 == .install(frozen: false) }.count == 1)
        runner.dismissBanner()
        #expect(runner.banner == nil && runner.toast != nil)
    }

    @Test(.timeLimit(.minutes(1))) func anyOtherBannerGivesWayToTheNextToast() async {
        let (runner, store) = await failedSync(exit: 3)
        #expect(runner.banner != nil)
        await client.json(.doctor(fix: false), in: scope, DesignFixtures.text("doctor.api", "json"), exit: 1)
        await runner.check(in: store)
        #expect(runner.banner == nil && runner.toast != nil)
    }

    @Test func aBannerReplacesTheToast() {
        let runner = ActionRunner(queue: MutationQueue())
        runner.outcome = .toast(ToastMessage(text: "Synced api"))
        runner.outcome = .banner(UserMessage(title: "Couldn’t sync."), id: UUID())
        #expect(runner.toast == nil && runner.banner?.title == "Couldn’t sync.")
        runner.outcome = nil
        #expect(runner.toast == nil && runner.banner == nil && runner.outcome == nil)
    }

    // MARK: - Details

    @Test(.timeLimit(.minutes(1))) func theToastsDetailsNameItsRun() async {
        await client.lines(.install(frozen: false), in: scope, ["Installing pdf 1.2.0 (packagist)…"])
        let store = store()
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store)
        guard let toast = runner.toast, let run = runner.activity.first else {
            Issue.record("sync did not toast")
            return
        }
        #expect(toast.showsDetails)
        #expect(toast.id == run.id)
        #expect(runner.detailsRequest == nil)
        runner.showDetails(of: toast.id)
        #expect(runner.detailsRequest == run.id)
    }

    @Test(.timeLimit(.minutes(1))) func theBannersDetailsNameItsRun() async {
        let (runner, store) = await failedSync(exit: 2)
        #expect(runner.bannerID != nil && runner.bannerID == runner.activity.first?.id)
        withExtendedLifetime(store) {}
    }

    // MARK: - Health popover

    @Test func problemsGroupWithTheirRemedies() throws {
        let doctor = try #require(DesignFixtures.api.doctor)
        let report = HealthReport.resolve(doctor)
        #expect(report.severity == .error)
        #expect(report.title == "Health · 6 problems")
        #expect(report.groups.map(\.kind) == [.problems])
        #expect(report.groups.first?.label == "Problems · Repair or Sync fixes these")
        #expect(
            report.groups.first?.items.map(\.hint) == [
                "Sync installs the skill and links it. Repair does not download.",
                "Repair relinks it.",
                "Sync installs the skill and links it. Repair does not download.",
                "Repair rewrites the block.", "Sync installs it. Repair does not download.",
                "Sync installs it. Repair does not download.",
            ])
        #expect(report.groups.first?.items.allSatisfy { $0.line.hint == nil } == true)
        #expect(report.canRepair && report.secondary == .sync)
        #expect(report.footnote == "Repair fixes links, the git index and .gitignore. It downloads nothing.")
        #expect(report.passedLabel == "2 checks passed" && report.passed.count == 2)
    }

    @Test func afterRepairTheRepairedComeFirstAndOnlyADownloadIsLeft() throws {
        let doctor = try #require(DesignFixtures.apiRepaired.doctor)
        let report = HealthReport.resolve(doctor)
        #expect(report.title == "Health · 4 problems")
        #expect(report.groups.map(\.kind) == [.repaired, .problems])
        #expect(report.groups.map(\.label) == ["Repaired · 2", "Problems · Sync fixes these"])
        #expect(report.groups[0].items.first?.line.sentence == "Relinked .claude/skills/pdf to the installed copy.")
        #expect(report.groups[1].items.map(\.hint) == Array(repeating: nil, count: 4), "the label already says Sync")
        #expect(!report.canRepair && report.secondary == .sync)
        #expect(report.footnote == "The remaining items need a download.")
    }

    @Test func allPassedOffersCheckAgain() throws {
        let doctor = try #require(DesignFixtures.website.doctor)
        let report = HealthReport.resolve(doctor)
        #expect(report.severity == .ok)
        #expect(report.title == "Health · all good")
        #expect(report.groups.isEmpty)
        #expect(!report.canRepair && report.secondary == .checkAgain)
        #expect(report.footnote == "Nothing to repair. Check runs again when the project opens or on ⌘R.")
        #expect(report.passed.count == doctor.passed.count)
    }

    /// A doctor answer over the api status, from its four lists.
    func doctor(
        problems: [String] = [], fixed: [String] = [], warnings: [String] = [], passed: [String] = []
    ) throws -> ScopeSnapshot.Doctor {
        let status = try JSONDecoder()
            .decode(StatusDocument.self, from: Data(DesignFixtures.text("status.api", "json").utf8))
        let json = try JSONSerialization.data(withJSONObject: [
            "ok": problems.isEmpty, "passed": passed, "problems": problems, "fixed": fixed, "warnings": warnings,
        ])
        let document = try JSONDecoder().decode(DoctorDocument.self, from: json)
        return try #require(ScopeSnapshot(status: status, audit: nil, doctor: document, outdated: nil).doctor)
    }

    static let missingLink = ".cursor/skills/jira-syntax: link missing"
    static let notInstalled =
        ".skillcask/skills/jira-syntax: not installed (netresearch/agent-jira-skill); run `skillcask install`"
    static let notOurs = ".claude/skills/x exists and was not created by skillcask; move it away"

    @Test func aLinkToASkillThatIsNotInstalledIsSyncs() throws {
        let doctor = try #require(DesignFixtures.api.doctor)
        #expect(doctor.remedy(of: DoctorItem(line: Self.missingLink)) == .sync)
        #expect(doctor.remedy(of: DoctorItem(line: ".cursor/skills/pdf: link wrong")) == .repair)
        #expect(
            doctor.remedy(of: DoctorItem(line: ".claude/skills/jira-syntax: link missing")) == .sync,
            "the jira-syntax link is the missing skill's problem")
        let onlyDownload = try self.doctor(problems: [Self.missingLink, Self.notInstalled])
        #expect(!onlyDownload.canRepair)
        let report = HealthReport.resolve(onlyDownload)
        #expect(report.groups.first?.label == "Problems · Sync fixes these")
        // Without the not-installed line the link is Repair's again (the folder exists).
        #expect(try self.doctor(problems: [Self.missingLink]).canRepair)
    }

    @Test func anItemNothingFixesMakesThePlainLabel() throws {
        let mixed = HealthReport.resolve(try doctor(problems: [Self.notOurs, ".gitignore: stale managed block"]))
        #expect(mixed.groups.first?.label == "Problems")
        #expect(
            mixed.groups.first?.items.map(\.hint) == ["Move it away, then Check Again.", "Repair rewrites the block."])
        let foreign = HealthReport.resolve(
            try doctor(problems: [".claude/skills/y: link foreign", ".cursor/skills/pdf: link wrong"]))
        #expect(foreign.groups.first?.label == "Problems")
        let repairOnly = HealthReport.resolve(
            try doctor(problems: [".gitignore: stale managed block", ".cursor/skills/pdf: link wrong"]))
        #expect(repairOnly.groups.first?.label == "Problems · Repair fixes these")
    }

    @Test func theStaleBlockHintSaysRewrite() {
        let item = DoctorItem(line: ".gitignore: stale managed block")
        #expect(RunningCopy.remedyHint(item, remedy: item.remedy) == "Repair rewrites the block.")
    }

    @Test func theRemainingFootnoteOnlyWhenEverythingLeftIsADownload() throws {
        let mixed = HealthReport.resolve(
            try doctor(problems: [Self.notInstalled, Self.notOurs], fixed: [".gitignore: stale managed block"]))
        #expect(mixed.footnote == RunningCopy.repairFootnote)
        let download = HealthReport.resolve(
            try doctor(problems: [Self.notInstalled], fixed: [".gitignore: stale managed block"]))
        #expect(download.footnote == "The remaining item needs a download.")
    }

    @Test(.timeLimit(.minutes(1))) func repairKeepsWhatItFixedUntilTheNextCheck() async throws {
        let repaired = DesignFixtures.text("doctor.api-repaired", "json")
        // What `doctor` without --fix says afterwards: the same open items, nothing in `fixed`.
        let after = try String(
            decoding: JSONSerialization.data(withJSONObject: [
                "ok": false, "passed": [String](), "fixed": [String](), "warnings": [String](),
                "problems": DesignFixtures.healthRepaired.problems,
            ]), as: UTF8.self)
        await trio(DesignFixtures.text("doctor.api", "json"))
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        await store.refresh()
        #expect(store.snapshot?.doctor?.fixed.isEmpty == true)

        await client.json(.doctor(fix: true), in: scope, repaired, exit: 1)
        await trio(after)
        let runner = ActionRunner(queue: MutationQueue())
        await runner.repair(in: store)
        let doctor = try #require(store.snapshot?.doctor)
        #expect(doctor.fixed == [".claude/skills/pdf: link wrong", ".gitignore: stale managed block"])
        let report = HealthReport.resolve(doctor)
        #expect(report.groups.map(\.kind) == [.repaired, .problems])
        #expect(report.footnote == "The remaining items need a download.")
        let checkedAt = try #require(store.snapshot?.checkedAt)
        #expect(RunningCopy.when(checkedAt, repaired: !doctor.fixed.isEmpty) == "Repaired just now")

        await client.json(.doctor(fix: false), in: scope, after, exit: 1)
        await trio(after)
        await runner.check(in: store)
        #expect(store.snapshot?.doctor?.fixed.isEmpty == true, "the next check drops the repaired items")
        #expect(store.snapshot?.doctor?.problems.count == 4)
    }

    /// A store refreshed once over the api trio, and the `doctor` answer that follows a Repair (open items only).
    func repairScenario() async throws -> (ScopeStore, after: String) {
        let after = try String(
            decoding: JSONSerialization.data(withJSONObject: [
                "ok": false, "passed": [String](), "fixed": [String](), "warnings": [String](),
                "problems": DesignFixtures.healthRepaired.problems,
            ]), as: UTF8.self)
        await trio(DesignFixtures.text("doctor.api", "json"))
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        await store.refresh()
        await client.json(.doctor(fix: true), in: scope, DesignFixtures.text("doctor.api-repaired", "json"), exit: 1)
        return (store, after)
    }

    func trio(_ doctor: String, gate: Gate? = nil) async {
        await client.json(.status, in: scope, DesignFixtures.text("status.api", "json"), gate: gate)
        await client.json(.audit, in: scope, DesignFixtures.text("audit.api", "json"))
        await client.json(.doctor(fix: false), in: scope, doctor, exit: 1)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedFollowUpDropsTheRepair() async throws {
        let (store, after) = try await repairScenario()
        await client.script(
            .status, in: scope, .error(.failed(code: .file, message: "skills.toml vanished", hint: nil, stderr: "")))
        await client.json(.audit, in: scope, DesignFixtures.text("audit.api", "json"))
        await client.json(.doctor(fix: false), in: scope, after, exit: 1)
        await ActionRunner(queue: MutationQueue()).repair(in: store)
        #expect(store.snapshot?.doctor?.fixed.isEmpty == true)
        await trio(after)
        await store.refresh()
        #expect(store.snapshot?.doctor?.fixed.isEmpty == true, "a later refresh does not bring it back")
    }

    @Test(.timeLimit(.minutes(1))) func aRefreshLandingAfterTheRepairsStartWins() async throws {
        let (store, after) = try await repairScenario()
        let gate = Gate()
        await trio(after, gate: gate)  // the Repair's follow-up, held at `status`
        await trio(after)  // ⌘R
        let runner = ActionRunner(queue: MutationQueue())
        let repair = Task { await runner.repair(in: store) }
        await gate.arrived()
        await store.refresh()
        #expect(store.snapshot?.doctor?.fixed.isEmpty == true)
        await gate.open()
        await repair.value
        #expect(store.snapshot?.doctor?.fixed.isEmpty == true, "the superseded follow-up does not land")
        #expect(store.snapshot?.doctor?.problems.count == 4)
    }

    @Test func warningsAreTheirOwnGroupWithHints() throws {
        let status = try JSONDecoder()
            .decode(
                StatusDocument.self, from: Data(DesignFixtures.text("status.api", "json").utf8))
        let doctor = try JSONDecoder()
            .decode(
                DoctorDocument.self,
                from: Data(
                    #"""
                    {"ok":false,"passed":[],"fixed":[],
                     "problems":[".claude/skills/x exists and was not created by skillcask; move it away"],
                     "warnings":[".gitignore: stale managed block"]}
                    """#
                    .utf8))
        let snapshot = ScopeSnapshot(status: status, audit: nil, doctor: doctor, outdated: nil)
        let report = HealthReport.resolve(try #require(snapshot.doctor))
        #expect(report.title == "Health · 1 problem, 1 warning")
        #expect(report.groups.map(\.kind) == [.problems, .warnings])
        #expect(report.groups.map(\.label) == ["Problems", "Warnings · decide yourself"])
        #expect(report.groups[0].items.first?.hint == "Move it away, then Check Again.")
        #expect(report.groups[1].items.first?.hint == "Repair rewrites the block.")
        #expect(report.canRepair && report.secondary == .sync)
        #expect(report.passed.isEmpty)
    }

    nonisolated static let labels: [(Set<DoctorItem.Remedy>, Int, String)] = [
        ([.repair, .sync], 2, "Problems · Repair or Sync fixes these"),
        ([.repair, .sync], 1, "Problems · Repair or Sync fixes this"),
        ([.sync], 1, "Problems · Sync fixes this"),
        ([.repair], 3, "Problems · Repair fixes these"),
        ([], 1, "Problems"),
    ]

    @Test(arguments: labels)
    func problemLabels(remedies: Set<DoctorItem.Remedy>, count: Int, label: String) {
        #expect(RunningCopy.problemsGroup(remedies, count: count) == label)
    }

    @Test func whenSaysCheckedOrRepaired() {
        let now = Date()
        #expect(RunningCopy.when(now.addingTimeInterval(-4 * 60), repaired: false, now: now) == "Checked 4 min ago")
        #expect(RunningCopy.when(now.addingTimeInterval(-2), repaired: true, now: now) == "Repaired just now")
    }
}
