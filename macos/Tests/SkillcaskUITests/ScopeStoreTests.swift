import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The refresh policy through the `CLIClient` fake: the generation guard, selection across refreshes,
/// `outdated` only on an explicit check, and the targeted refresh a mutation asks for.
@Suite @MainActor struct ScopeStoreTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/scope-store-tests"))
    let capabilities = Capabilities(version: Capabilities.minimum)

    func store() -> ScopeStore {
        ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in
            SkillText.parse("# fake")
        }
    }

    static func status(_ skills: [(name: String, version: String)]) -> String {
        let entries = skills.map {
            #"{"package":"acme/\#($0.name)","skill":"\#($0.name)","version":"\#($0.version)","state":"ok","ok":true}"#
        }
        return #"{"ok":true,"entries":[\#(entries.joined(separator: ","))],"policy":{},"repositories":[]}"#
    }

    static let emptyAudit = #"{"ok":true,"skills":[]}"#
    static let cleanDoctor = #"{"ok":true,"passed":["links: 1 ok"],"problems":[],"fixed":[],"warnings":[]}"#

    /// The trio one refresh needs.
    func scriptTrio(_ status: String, gate: Gate? = nil) async {
        await client.json(.status, in: scope, status, gate: gate)
        await client.json(.audit, in: scope, Self.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, Self.cleanDoctor)
    }

    @Test(.timeLimit(.minutes(1))) func lateResultFromAnOlderRefreshIsDropped() async {
        let slow = Gate()
        await scriptTrio(Self.status([("old", "1.0.0")]), gate: slow)
        await scriptTrio(Self.status([("new", "2.0.0")]))
        let store = store()
        let first = Task { await store.refresh() }
        await slow.arrived()
        await store.refresh()
        #expect(store.snapshot?.entries.map(\.name) == ["new"])
        await slow.open()
        await first.value
        #expect(store.snapshot?.entries.map(\.name) == ["new"])
        #expect(!store.isRefreshing)
        #expect(store.presentation == .ready)
    }

    /// A `doctor` that fails after one that answered: Health keeps the older document, but the agent links are not
    /// claimed from it (a skill added since would read "linked" without a check).
    @Test(.timeLimit(.minutes(1))) func aFailedDoctorLeavesTheAgentLinksUnchecked() async throws {
        let status =
            #"{"ok":true,"entries":[{"package":"acme/pdf","skill":"pdf","version":"1.0.0","state":"ok","ok":true}],"policy":{},"targets":{"entries":["claude","cursor"],"dirs":[".claude/skills"],"from":"default"}}"#
        await scriptTrio(status)
        await client.json(.status, in: scope, status)
        await client.json(.audit, in: scope, Self.emptyAudit)
        await client.script(
            .doctor(fix: false), in: scope,
            .error(.failed(code: .other(1), message: "doctor broke", hint: nil, stderr: "")))
        let store = store()
        await store.refresh()
        let pdf = try #require(store.snapshot?.entry(id: "pdf"))
        #expect(store.agentReach(for: pdf).links.map(\.state) == [.linked, .linked])
        await store.refresh()
        #expect(store.snapshot?.doctor != nil, "Health keeps the last answer")
        #expect(store.agentIndex.check == .failed)
        #expect(store.agentReach(for: pdf).links.map(\.state) == [.unknown, .unknown])
        // Nothing scripted: the whole refresh fails and clears the partial-failure strip, but the snapshot on screen
        // keeps its older `doctor` answer, so its links stay unchecked.
        await store.refresh()
        #expect(store.lastError != nil && store.partialFailure == nil)
        #expect(store.agentIndex.check == .failed)
        #expect(store.agentReach(for: pdf).links.map(\.state) == [.unknown, .unknown])
    }

    @Test(.timeLimit(.minutes(1))) func selectionSurvivesARefreshWithANewVersion() async {
        await scriptTrio(Self.status([("pdf", "1.2.0"), ("docx", "1.0.0")]))
        await scriptTrio(Self.status([("docx", "1.0.0"), ("pdf", "1.4.0")]))
        await client.json(.info(.skill("pdf")), in: scope, #"{"skill":"pdf","kind":"package","path":"x","from":"y"}"#)
        let store = store()
        await store.refresh()
        await store.select("pdf")
        #expect(store.selectedEntry?.version == "1.2.0")
        await store.refresh()
        #expect(store.selection == "pdf")
        #expect(store.selectedEntry?.version == "1.4.0")
    }

    @Test(.timeLimit(.minutes(1))) func aVanishedSelectionClearsAndTheOverviewShows() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await scriptTrio(Self.status([("docx", "1.0.0")]))
        let store = store()
        await store.refresh()
        store.selection = "pdf"
        await store.refresh()
        #expect(store.selection == nil && store.selectedEntry == nil)
    }

    @Test(.timeLimit(.minutes(1))) func outdatedNeverRunsOnOpenOnlyOnCheck() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let store = store()
        await store.refreshIfStale()
        #expect(await !client.commands.contains(.outdated))
        #expect(store.snapshot?.updatesChecked == false)
        await client.json(
            .outdated, in: scope,
            #"{"packages":[{"package":"acme/pdf","locked":"1.2.0","within":"1.4.0","latest":"1.4.0"}],"behind":["acme/pdf 1.2.0 -> 1.4.0"]}"#
        )
        await store.checkUpdates()
        #expect(await client.commands.filter { $0 == .outdated }.count == 1)
        #expect(store.snapshot?.availableUpdates.map(\.package) == ["acme/pdf"])
        #expect(store.selectedEntry == nil && store.snapshot?.entry(id: "pdf")?.hasUpdate == true)
    }

    @Test(.timeLimit(.minutes(1))) func sortMenuOrdersTheVisibleEntries() async {
        await scriptTrio(Self.status([("b", "1.0.0"), ("a", "1.0.0")]))
        let store = store()
        await store.refresh()
        #expect(store.sort == .state && store.visibleEntries.map(\.name) == ["a", "b"])
        store.sort = .name
        #expect(store.visibleEntries.map(\.name) == ["a", "b"])
        store.sort = .source
        #expect(store.visibleEntries.map(\.name) == ["a", "b"])
        store.query = "b"
        #expect(store.visibleEntries.map(\.name) == ["b"])
    }

    @Test(.timeLimit(.minutes(1))) func aCheckNeverDropsAnInFlightTrio() async {
        let slow = Gate()
        await scriptTrio(Self.status([("pdf", "1.2.0")]), gate: slow)
        await client.json(
            .outdated, in: scope,
            #"{"packages":[{"package":"acme/pdf","locked":"1.2.0","within":"1.4.0","latest":"1.4.0"}],"behind":[]}"#)
        let store = store()
        let trio = Task { await store.refresh() }
        await slow.arrived()
        await store.checkUpdates()
        #expect(store.snapshot == nil && !store.isCheckingUpdates)
        await slow.open()
        await trio.value
        #expect(store.snapshot?.entries.count == 1 && store.snapshot?.updatesChecked == true)
        #expect(store.snapshot?.entry(id: "pdf")?.hasUpdate == true)
    }

    @Test(.timeLimit(.minutes(1))) func checkOnOpenRunsOutdatedAfterTheFirstTrioOnly() async {
        let name = "ScopeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        let settings = SettingsStore(defaults: defaults)
        settings.checkUpdatesOnOpen = true
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await client.json(.outdated, in: scope, #"{"packages":[],"behind":[]}"#)
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities, settings: settings)
        await store.refreshIfStale()
        #expect(await client.commands.filter { $0 == .outdated }.count == 1)
        await store.refreshIfStale()
        #expect(await client.commands.filter { $0 == .outdated }.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func autoRefreshWaitsWhileAMutationOfTheScopeRuns() async {
        let queue = MutationQueue()
        let gate = Gate()
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities, queue: queue)
        let mutation = Task { try await queue.enqueue(in: scope) { await gate.wait() } }
        await gate.arrived()
        await store.refreshIfStale()
        #expect(await client.commands.isEmpty)
        await gate.open()
        _ = try? await mutation.value
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await store.refreshIfStale()
        #expect(await client.commands.contains(.status))
    }

    @Test(.timeLimit(.minutes(1))) func oneRunAtATimeInTheWholeApp() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let gate = Gate()
        await client.lines(.install(frozen: false), in: scope, [], gate: gate)
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let store = store()
        await store.refresh()
        let runner = ActionRunner(queue: MutationQueue())
        let sync = Task { await runner.sync(in: store) }
        await gate.arrived()
        #expect(runner.isRunning)
        await runner.check(in: store)
        #expect(runner.activity.isEmpty, "a second run while one is in flight does nothing")
        await gate.open()
        await sync.value
        #expect(!runner.isRunning && runner.activity.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aFreshScopeIsNotRefreshedAgain() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let store = store()
        await store.refreshIfStale()
        await store.refreshIfStale()
        #expect(await client.commands.filter { $0 == .status }.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aNetworkFailureOnCheckKeepsTheSnapshotAndGoesOffline() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await client.script(
            .outdated, in: scope, .error(.failed(code: .network, message: "no route", hint: nil, stderr: "")))
        let store = store()
        await store.refresh()
        await store.checkUpdates()
        #expect(store.presentation == .offline && store.isOffline)
        #expect(store.snapshot?.entries.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aFailedFirstLoadBecomesAPresentation() async {
        await client.script(
            .status, in: scope,
            .error(.failed(code: .problem, message: "skills.toml not found", hint: "run skillcask init", stderr: "")))
        await client.json(.audit, in: scope, Self.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, Self.cleanDoctor)
        let store = store()
        await store.refresh()
        #expect(store.presentation == .noManifest && store.snapshot == nil)
    }

    @Test(.timeLimit(.minutes(1))) func syncRunsInstallThenTheOfflineTrio() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await client.lines(.install(frozen: false), in: scope, ["Installing pdf 1.2.0 (packagist)…"])
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let store = store()
        await store.refresh()
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store)
        let commands = await client.commands
        #expect(commands.count == 7)
        #expect(commands[3] == .install(frozen: false))
        #expect(Set(commands[4...]) == [.status, .audit, .doctor(fix: false)])
        #expect(!commands.contains(.outdated))
        #expect(runner.current == nil)
        #expect(runner.activity.count == 1 && runner.activity.first?.status == .exited(0))
        #expect(runner.activity.first?.transcript == [.stdout("Installing pdf 1.2.0 (packagist)…")])
        if case .toast(let message) = runner.outcome {
            #expect(message.text == ActionCopy.synced("scope-store-tests"))
        } else {
            Issue.record("sync did not end with a toast: \(String(describing: runner.outcome))")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aFailedSyncShowsABannerAndStillRefreshes() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await client.script(
            .install(frozen: false), in: scope,
            .error(.failed(code: .signIn, message: "git.acme.example needs you to sign in", hint: nil, stderr: "")))
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let store = store()
        await store.refresh()
        let runner = ActionRunner(queue: MutationQueue())
        await runner.sync(in: store)
        #expect(await client.commands.filter { $0 == .status }.count == 2)
        if case .banner(let message, _) = runner.outcome {
            #expect(message.title == "Couldn’t sync.")
            #expect(message.remedy == .signIn)
        } else {
            Issue.record("a failed sync did not end with a banner")
        }
    }

    @Test(.timeLimit(.minutes(1))) func checkIsDoctorWithoutFixAndExitOneWithADocumentSucceeds() async {
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        await client.json(
            .doctor(fix: false), in: scope,
            #"{"ok":false,"passed":[],"problems":[".gitignore: stale managed block"],"fixed":[],"warnings":[]}"#,
            exit: 1)
        await scriptTrio(Self.status([("pdf", "1.2.0")]))
        let store = store()
        await store.refresh()
        let runner = ActionRunner(queue: MutationQueue())
        await runner.check(in: store)
        #expect(runner.activity.first?.error == nil)
        if case .toast = runner.outcome {} else { Issue.record("check with problems is still a successful run") }
    }
}
