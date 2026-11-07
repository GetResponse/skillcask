import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// What the app says after a run matches what the CLI did: a refresh that lost `audit` or `doctor` keeps the
/// last answer and says so, Repair counts what it left, Sync names a resolve, Remove a kept folder, Update the
/// version actually locked; the run verdict needs a JSON document at exit 0 or 1.
@Suite @MainActor struct TruthfulOutcomeTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/truthful-outcome-tests"))
    let capabilities = Capabilities(version: Capabilities.minimum)

    func store(preloaded: Bool = true) -> ScopeStore {
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        if preloaded {
            store.preload(snapshot: DesignFixtures.api)
        }
        return store
    }

    // MARK: - Partial refresh

    /// `audit` and `doctor` fail on the second refresh: the first refresh's Health stays, the header says both are
    /// from an earlier check, and the next refresh in which both answer clears the warning.
    @Test(.timeLimit(.minutes(1))) func aFailedAuditOrDoctorKeepsTheLastDocument() async throws {
        let failure = CLIError.failed(code: .file, message: "cannot read skills.lock", hint: nil, stderr: "")
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]))
        await client.script(.audit, in: scope, .error(failure))
        await client.script(.doctor(fix: false), in: scope, .error(failure))
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let store = store(preloaded: false)
        await store.refresh()
        #expect(store.partialFailure == nil)
        await store.refresh()
        let partial = try #require(store.partialFailure)
        #expect(partial.failed == [.audit, .doctor] && partial.kept == [.audit, .doctor] && partial.error == failure)
        #expect(store.snapshot?.doctor?.passed == ["links: 1 ok"], "Health is the first refresh's")
        #expect(
            StripCopy.partialRefresh(partial)
                == "Security findings are from an earlier check: audit failed. Health is from an earlier check: "
                + "doctor failed.")
        await store.refresh()
        #expect(store.partialFailure == nil)
    }

    /// A refresh whose `status` fails replaces the partial warning with `refreshError`: no strip about an older
    /// refresh's `audit` stays beside it. The strip's Details show the failure.
    @Test(.timeLimit(.minutes(1))) func aWholeFailedRefreshClearsThePartialWarning() async throws {
        let failure = CLIError.failed(code: .file, message: "cannot read skills.lock", hint: nil, stderr: "io: denied")
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]))
        await client.script(.audit, in: scope, .error(failure))
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        await client.script(.status, in: scope, .error(failure))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let store = store(preloaded: false)
        await store.refresh()
        let partial = try #require(store.partialFailure)
        #expect(PartialRefreshStrip.details(of: partial.error) == "Cannot read skills.lock.\nio: denied")
        await store.refresh()
        #expect(store.partialFailure == nil && store.refreshError == failure && store.snapshot != nil)
    }

    /// On a first load nothing stands in: the warning says the findings are missing.
    @Test(.timeLimit(.minutes(1))) func aFirstLoadWithoutAuditSaysTheFindingsAreMissing() async throws {
        await client.json(.status, in: scope, ScopeStoreTests.status([("pdf", "1.2.0")]))
        await client.script(.audit, in: scope, .error(.noDocument))
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let store = store(preloaded: false)
        await store.refresh()
        let partial = try #require(store.partialFailure)
        #expect(partial.failed == [.audit] && partial.kept.isEmpty)
        #expect(StripCopy.partialRefresh(partial) == "Security findings are missing: audit failed.")
        #expect(store.presentation == .ready)
    }

    // MARK: - Verdict

    func result(_ command: Invocation.Command, _ stdout: String, _ status: SkillcaskCore.ExitStatus) throws -> RunResult
    {
        RunResult(
            invocation: try Invocation(command, in: scope, capabilities: capabilities), status: status,
            stdout: Data(stdout.utf8), stderr: "error: boom\n")
    }

    /// A document counts at exit 0 or 1 only, and only when it is JSON; a signal or another exit is the failure
    /// it stands for whatever stdout holds.
    @Test func theVerdictNeedsAJSONDocumentAtExitZeroOrOne() throws {
        let doctor = ScopeStoreTests.cleanDoctor
        #expect(ActionRunner.verdict(of: try result(.doctor(fix: true), doctor, .exited(0))) == nil)
        #expect(ActionRunner.verdict(of: try result(.doctor(fix: true), doctor, .exited(1))) == nil)
        #expect(ActionRunner.verdict(of: try result(.doctor(fix: true), doctor, .exited(3)))?.isFailed(3) == true)
        #expect(ActionRunner.verdict(of: try result(.doctor(fix: true), doctor, .signaled(9))) == .killed(signal: 9))
        guard case .decode = ActionRunner.verdict(of: try result(.doctor(fix: true), "half {", .exited(1))) else {
            Issue.record("stdout that is not JSON is unreadable")
            return
        }
        // Regression: Repair reported success when its JSON did not decode as a doctor document.
        guard case .decode = ActionRunner.verdict(of: try result(.doctor(fix: true), #"{"x":1}"#, .exited(0))) else {
            Issue.record("a repair without a doctor document is not a success")
            return
        }
        #expect(ActionRunner.verdict(of: try result(.doctor(fix: false), "", .exited(0))) == .noDocument)
        #expect(ActionRunner.verdict(of: try result(.install(frozen: false), "", .exited(0))) == nil)
    }

    // MARK: - Repair

    /// `doctor --fix --json` with problems left exits 1 with `ok: false` (`src/commands.rs` `doctor`): the toast
    /// counts both, in the warning tone; a clean Repair keeps its plain toast.
    @Test(.timeLimit(.minutes(1))) func aRepairThatLeftProblemsSaysSo() async {
        let left = #"{"ok":false,"passed":[],"problems":["a","b"],"fixed":["links"],"warnings":[]}"#
        await client.json(.doctor(fix: true), in: scope, left, exit: 1)
        await client.json(.doctor(fix: true), in: scope, ScopeStoreTests.cleanDoctor)
        let runner = ActionRunner(queue: MutationQueue())
        let store = store()
        await runner.repair(in: store)
        #expect(runner.toast?.text == "Repaired 1 in truthful-outcome-tests, 2 problems left")
        #expect(runner.toast?.tone == .warning && runner.banner == nil)
        await runner.repair(in: store)
        #expect(runner.toast?.text == ActionCopy.repaired("truthful-outcome-tests") && runner.toast?.tone == .success)
        #expect(ActionCopy.repaired("api", fixed: 0, left: 1) == "Nothing repaired in api, 1 problem left")
    }

    // MARK: - Sync

    /// A row whose skills.toml entry drifted from the lock: plain `install` resolves and rewrites the lock, and the
    /// title, toast and help say so; without drift Sync keeps its words.
    @Test(.timeLimit(.minutes(1))) func syncOnDriftSaysItResolves() async throws {
        let drifted = #"""
            {"ok":false,"entries":[{"package":"acme/pdf","skill":"pdf","version":"1.2.0",
            "state":"constraint changed from \"^1\" to \"^2\"","ok":false}],"policy":{},"repositories":[]}
            """#
        await client.json(.status, in: scope, drifted)
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
        let store = store(preloaded: false)
        await store.refresh()
        #expect(ActionRunner.syncResolves(store.snapshot) && !ActionRunner.syncResolves(DesignFixtures.api))
        await client.lines(.install(frozen: false), in: scope, ["installed pdf (acme/pdf 2.0.0)"])
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store)
        let run = try #require(runner.activity.first)
        #expect(run.title == ActionCopy.resolving)
        #expect(runner.toast?.text == "Resolved truthful-outcome-tests · skills.lock updated, 1 skill installed")
        #expect(await client.commands.contains(.install(frozen: false)))
    }

    // MARK: - Transcript order

    /// Lines reach the live transcript through one ordered stream, all of them before the run is recorded.
    @Test(.timeLimit(.minutes(1))) func theTranscriptKeepsTheOrderOfTheLines() async throws {
        let lines = (0..<500).map { "line \($0)" }
        await client.lines(.install(frozen: false), in: scope, lines)
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store())
        let run = try #require(runner.activity.first)
        #expect(run.transcript == lines.map(OutputLine.stdout))
    }

    // MARK: - Remove

    /// `warning: kept <path>: modified or not installed by skillcask` (`src/commands.rs` `materialize`): that
    /// skill's folder stays, so the toast never calls it removed.
    @Test func aKeptFolderIsNotCalledRemoved() {
        let transcript: [OutputLine] = [
            .stdout("removed sql"),
            .stderr("warning: kept .agents/skills/pdf: modified or not installed by skillcask"),
        ]
        #expect(RemoveAlert.keptCopies(in: transcript) == ["pdf"])
        #expect(
            RemoveAlert.toast(
                removed: ["pdf", "sql"], packageOf: ["pdf": "acme/pdf", "sql": "acme/sql"], transcript: transcript,
                scope: "api")
                == "Removed sql from api; kept pdf’s folder (not Skillcask’s copy)")
        let personal: [OutputLine] = [
            .stderr("warning: kept ~/.agents/skills/pdf: modified or not installed by skillcask")
        ]
        #expect(
            RemoveAlert.toast(
                removed: ["pdf"], packageOf: ["pdf": "acme/pdf"], transcript: personal, scope: "My Skills")
                == "Kept pdf’s folder in My Skills (not Skillcask’s copy)")
    }

    // MARK: - Update

    /// `updated <package> <from> -> <to>` with another `to` than the sheet reviewed: the toast names what was
    /// locked; with no line at all the CLI updated nothing for it (`src/commands.rs` 1645-1651), and the toast says
    /// it stayed. The reviewed version, or a `locked` line for a new package, says nothing extra.
    @Test func anUpdateThatLockedAnotherVersionOrNothingSaysWhich() throws {
        let pdf = ReviewUpdateCopy.Reviewed(package: "acme/pdf", name: "pdf", from: "1.2.0", to: "1.4.0")
        let sql = ReviewUpdateCopy.Reviewed(package: "acme/sql", name: "sql", from: "2.0.0", to: "2.1.0")
        let other: [OutputLine] = [.stdout("updated acme/pdf 1.2.0 -> 1.4.1")]
        let locked = try #require(ReviewStore.lockedOther([pdf], transcript: other))
        #expect(
            ReviewUpdateCopy.updatedOther([pdf], locked, single: true) == "Updated pdf to 1.4.1, not the reviewed 1.4.0"
        )
        #expect(ReviewStore.lockedOther([pdf], transcript: [.stdout("updated acme/pdf 1.2.0 -> 1.4.0")]) == nil)
        #expect(ReviewStore.lockedOther([pdf], transcript: [.stdout("locked acme/pdf 1.4.0")]) == nil)
        let none = try #require(ReviewStore.lockedOther([pdf], transcript: []))
        #expect(ReviewUpdateCopy.updatedOther([pdf], none, single: true) == "pdf was not updated; it stays at 1.2.0")
        let all: [OutputLine] = [.stdout("updated acme/sql 2.0.0 -> 2.1.0")]
        let partly = try #require(ReviewStore.lockedOther([pdf, sql], transcript: all))
        #expect(
            ReviewUpdateCopy.updatedOther([pdf, sql], partly, single: false)
                == "Updated sql · pdf was not updated; it stays at 1.2.0")
        let mixed: [OutputLine] = [.stdout("updated acme/pdf 1.2.0 -> 1.4.1")]
        let both = try #require(ReviewStore.lockedOther([pdf, sql], transcript: mixed))
        #expect(
            ReviewUpdateCopy.updatedOther([pdf, sql], both, single: false)
                == "Updated pdf · pdf is at 1.4.1, not the reviewed 1.4.0; sql was not updated; it stays at 2.0.0")
        let nothing = try #require(ReviewStore.lockedOther([pdf, sql], transcript: []))
        #expect(ReviewUpdateCopy.updatedOther([pdf, sql], nothing, single: false).hasPrefix("Nothing was updated · "))
    }

    // MARK: - Reveal in Finder

    /// Skill › Reveal in Finder: a plain relative path inside the root; `..`, absolute, `~` and a link out of the
    /// root are refused.
    @Test func revealStaysInsideTheScope() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: ".agents/skills/pdf"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: ".agents/skills/out"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(SkillcaskCommands.revealURL(path: ".agents/skills/pdf", root: root) != nil)
        for path in ["../x", "/etc", "~/x", ".agents/../../x", ".agents/skills/out", ""] {
            #expect(SkillcaskCommands.revealURL(path: path, root: root) == nil, "\(path)")
        }
    }
}

extension CLIError {
    /// A `.failed` with exit `code`.
    fileprivate func isFailed(_ code: Int32) -> Bool {
        if case .failed(let exit, _, _, _) = self { exit.status == code } else { false }
    }
}

/// skills.sh through `skillcask -g config` (D48): no search runs, and the app does not read config.toml itself;
/// the adopted folder is measured by the store, off the views.
@Suite @MainActor struct CLIConfigSettingsTests {
    let client = FakeCLIClient()
    let capabilities = Capabilities(version: Capabilities.minimum)
    static let read = Invocation.Command.config(key: CLISettingsStore.skillsShKey)

    func context() -> CLISettingsStore.Context {
        CLISettingsStore.Context(client: client, capabilities: capabilities)
    }

    func store() -> CLISettingsStore {
        CLISettingsStore()
    }

    @Test(arguments: [
        (#"{"from":null,"value":null}"#, Int32(1), CLISettingsStore.SkillsSh.notSet),
        (#"{"from":"config.toml","value":true}"#, 0, .on), (#"{"from":"config.toml","value":false}"#, 0, .off),
    ])
    func loadReadsConfig(json: String, exit: Int32, expected: CLISettingsStore.SkillsSh) async throws {
        await client.json(Self.read, in: .personal, json, exit: exit)
        let store = store()
        await store.loadSkillsSh(in: context())
        #expect(store.skillsSh == expected)
        let invocation = try #require(await client.invocations.first)
        #expect(invocation.argv == ["-g", "config", "--json", "--", "search.skills-sh"])
    }

    /// Regression: the read had no generation guard, so a cancelled read reset the switch to unknown and a slow
    /// earlier read could overwrite a later one.
    @Test func onlyTheNewestSkillsShReadCounts() async {
        let slow = Gate()
        await client.json(Self.read, in: .personal, #"{"from":"config.toml","value":false}"#, gate: slow)
        await client.json(Self.read, in: .personal, #"{"from":"system config.toml","value":true}"#)
        let store = store()
        let first = Task { await store.loadSkillsSh(in: context()) }
        await slow.arrived()
        await store.loadSkillsSh(in: context())
        await slow.open()
        await first.value
        #expect(store.skillsSh == .on && store.skillsShFrom == "system config.toml")
        #expect(SettingsCopy.storedIn(store.skillsShFrom) == "in system config.toml.")
        await client.script(Self.read, in: .personal, .error(.cancelled))
        await store.loadSkillsSh(in: context())
        #expect(store.skillsSh == .on)
    }

    /// A read that fails (a broken config.toml) leaves the switch unknown: nothing falls back to the file.
    @Test func aFailedReadLeavesTheSwitchUnknown() async {
        let broken = CLIError.failed(
            code: .problem, message: "config.toml: expected `=`", hint: nil, stderr: "")
        await client.script(Self.read, in: .personal, .error(broken))
        let store = store()
        await store.loadSkillsSh(in: context())
        #expect(store.skillsSh == .unknown)
        #expect(await client.invocations.count == 1)
    }

    /// The switch writes with `config -- search.skills-sh false` and reads back through `config`: no search.
    @Test func switchWritesThroughConfig() async throws {
        await client.lines(.configSet(key: CLISettingsStore.skillsShKey, values: ["false"]), in: .personal, [])
        await client.json(Self.read, in: .personal, #"{"from":"config.toml","value":false}"#)
        await client.json(.configList, in: .personal, #"{"file":"/c/config.toml","settings":{}}"#)
        let store = store()
        await store.setSkillsSh(false, in: context())
        #expect(store.skillsSh == .off && store.skillsShFailure == nil)
        let commands = await client.invocations.map(\.argv)
        #expect(
            commands == [
                ["-g", "config", "--", "search.skills-sh", "false"],
                [
                    "-g", "config", "--json", "--",
                    "search.skills-sh",
                ],
                ["-g", "config", "--json"],
            ])
        #expect(store.globalSettings?.file == "/c/config.toml", "Settings › Global reads the same key again")
    }

    /// A refused write says why, and the state is what `config` reads back.
    @Test func aRefusedWriteSaysWhy() async {
        let refused = CLIError.failed(
            code: .problem, message: "config.toml: search must be a table", hint: nil, stderr: "")
        await client.script(
            .configSet(key: CLISettingsStore.skillsShKey, values: ["true"]), in: .personal, .error(refused))
        await client.json(Self.read, in: .personal, #"{"from":null,"value":null}"#, exit: 1)
        let store = store()
        await store.setSkillsSh(true, in: context())
        #expect(store.skillsSh == .notSet && store.skillsShFailure?.title == SettingsCopy.couldNotSaveSkillsSh)
    }

    @Test func theAdoptedFolderIsMeasuredByTheStore() async {
        let folder = URL(fileURLWithPath: "/c/adopted")
        let store = CLISettingsStore(measure: { $0 == folder ? "4 folders · 1.2 MB" : nil })
        #expect(store.adoptedSummary(of: folder) == nil)
        await store.measureAdopted(at: folder)
        #expect(store.adoptedSummary(of: folder) == "4 folders · 1.2 MB")
        #expect(store.adoptedSummary(of: URL(fileURLWithPath: "/elsewhere")) == nil)
        let real = FileManager.default.temporaryDirectory.appending(path: "adopted-\(UUID().uuidString)")
        #expect(CLISettingsStore.measure(real) == nil, "a folder that does not exist has no summary")
    }
}
