import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// `GuardedClient` around the fake: a folder without skills.toml runs nothing the CLI would send to a parent
/// project (`src/project.rs` `find_root` walks up), and a read that never answers times out while a mutation does
/// not.
@Suite @MainActor struct GuardedClientTests {
    let client = FakeCLIClient()
    let bare = Scope.project(URL(fileURLWithPath: "/tmp/parent/sub"))
    let capabilities = Capabilities(version: Capabilities.minimum)

    func guarded(
        setUp: Bool = false, timeout: Duration = .seconds(120), network: Duration = .seconds(900)
    ) -> GuardedClient {
        GuardedClient(client, readTimeout: timeout, networkReadTimeout: network) { _ in setUp }
    }

    func invocation(_ command: Invocation.Command, in scope: Scope? = nil) throws -> Invocation {
        try Invocation(command, in: scope ?? bare, capabilities: capabilities)
    }

    /// Every command but `init` and `projects` is refused before the fake sees it, with the CLI's own words.
    @Test func aFolderWithoutAManifestRunsOnlyInitAndProjects() async throws {
        let guarded = guarded()
        for command in [
            Invocation.Command.status, .audit, .doctor(fix: false), .doctor(fix: true), .install(frozen: false),
            .remove(packages: ["acme/pdf"]),
        ] {
            await #expect(throws: GuardedClient.notSetUp) { try await guarded.run(invocation(command)) }
        }
        #expect(await client.invocations.isEmpty, "nothing reached the CLI")
        await client.lines(.initialize, in: bare, ["created skills.toml"])
        await client.json(.projects(roots: [bare.root]), in: bare, #"{"projects":[]}"#)
        _ = try await guarded.run(invocation(.initialize))
        _ = try await guarded.run(invocation(.projects(roots: [bare.root])))
        #expect(await client.commands == [.initialize, .projects(roots: [bare.root])])
        #expect(Presentation.forFailedLoad(GuardedClient.notSetUp) == .noManifest)
    }

    /// My Skills has no walk up (`-g`): never refused; a set-up project runs as before.
    @Test func thePersonalScopeAndASetUpProjectPass() async throws {
        await client.json(.status, in: .personal, ScopeStoreTests.status([]))
        await client.json(.status, in: bare, ScopeStoreTests.status([]))
        _ = try await guarded().run(invocation(.status, in: .personal))
        _ = try await guarded(setUp: true).run(invocation(.status))
        #expect(await client.commands == [.status, .status])
    }

    /// A read that never answers ends in `.timedOut` (and its child is cancelled); a mutation that outlives the
    /// same limit still ends normally.
    @Test(.timeLimit(.minutes(1))) func aReadTimesOutAndAMutationDoesNot() async throws {
        let guarded = guarded(setUp: true, timeout: .milliseconds(50))
        let gate = Gate()
        await client.lines(.install(frozen: false), in: bare, ["installed pdf (acme/pdf 1.0.0)"], gate: gate)
        let install = try invocation(.install(frozen: false))
        let mutation = Task { try await guarded.run(install) }
        await gate.arrived()
        await client.script(.status, in: bare, .never)
        await #expect(throws: CLIError.timedOut(after: .milliseconds(50))) {
            try await guarded.run(invocation(.status))
        }
        await gate.open()
        let result = try await mutation.value
        #expect(result.status == .exited(0), "the mutation ran past the read's limit and finished")
        #expect(
            ErrorCopy.message(for: .timedOut(after: .seconds(120))).action
                == "Skillcask stopped it after 2 minutes. Try again.")
        let timedOut = ErrorCopy.message(for: .timedOut(after: .seconds(120)))
        #expect(
            FailureBanner.symbol(for: timedOut) == FailureBanner.timeoutSymbol && FailureBanner.showsRetry(timedOut))
        #expect(ErrorCopy.timedOutAction(after: .seconds(900)) == "Skillcask stopped it after 15 minutes. Try again.")
        #expect(ErrorCopy.timedOutAction(after: .seconds(5)) == "Skillcask stopped it after 5 seconds. Try again.")
    }

    /// Reads that talk to registries (`outdated`, `diff`, `diff --to`, `info <package>`, `search`) get the 15 min
    /// ceiling, not the 2 min of the reads that stay on disk; a network read that hangs still ends.
    @Test(.timeLimit(.minutes(1))) func networkReadsGetTheLongerCeiling() async throws {
        let defaults = GuardedClient(client) { _ in true }
        for command in [
            Invocation.Command.outdated, .diff(package: nil), .diffTo(package: "a/b", version: "1.0"),
            .info(.package("a/b")), .search(query: "q", skillsSh: nil, remember: false),
        ] {
            #expect(defaults.limit(for: try invocation(command)) == .seconds(15 * 60), "\(command)")
        }
        for command in [
            Invocation.Command.status, .audit, .doctor(fix: false), .info(.skill("pdf")),
            .projects(roots: [bare.root]),
        ] {
            #expect(defaults.limit(for: try invocation(command)) == .seconds(120), "\(command)")
        }
        #expect(defaults.limit(for: try invocation(.install(frozen: false))) == nil)
        let short = guarded(setUp: true, timeout: .seconds(3600), network: .milliseconds(50))
        await client.script(.outdated, in: bare, .never)
        await #expect(throws: CLIError.timedOut(after: .milliseconds(50))) {
            try await short.run(invocation(.outdated))
        }
    }

    /// Opening the folder through the guard shows Set Up, runs no `status`, and asks the app to check the sidebar's
    /// set-up state again; a snapshot read before skills.toml went away is dropped, not left on screen.
    @Test(.timeLimit(.minutes(1))) func aRefreshWithoutAManifestShowsSetUpAndRechecks() async {
        let store = ScopeStore(scope: bare, client: guarded(), capabilities: capabilities) { _ in SkillText.parse("") }
        store.preload(snapshot: DesignFixtures.api, selection: "pdf")
        let rechecks = Count()
        store.onManifestMissing = { rechecks.value += 1 }
        await store.refresh()
        #expect(store.presentation == .noManifest && store.snapshot == nil && store.selection == nil)
        #expect(rechecks.value == 1)
        #expect(await client.invocations.isEmpty)
    }

    /// A project folder without skills.toml greys the Skill and Scope menus and the toolbar: `isSetUp` reads the
    /// manifest check; a scope outside the sidebar counts as set up.
    @Test func setUpStateComesFromTheManifestCheck() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "GuardedClientTests-\(UUID())") ?? .standard)
        settings.remember(project: bare.root)
        let app = AppStore(
            settings: settings, client: client, capabilities: capabilities, manifestExists: { _ in false })
        await app.refreshSetUp()
        #expect(!app.isSetUp(bare))
        #expect(app.isSetUp(.personal) && app.isSetUp(.project(URL(fileURLWithPath: "/tmp/elsewhere"))))
    }

    /// Regression: the app's own check took a directory named skills.toml for a manifest; the CLI's `find_root`
    /// wants a file, so the app's default is the guard's check.
    @Test func aFolderNamedSkillsTomlIsNotSetUp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GuardedClientTests-\(UUID())")
        try FileManager.default.createDirectory(
            at: root.appending(path: "skills.toml"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "GuardedClientTests-\(UUID())") ?? .standard)
        settings.remember(project: root)
        let app = AppStore(settings: settings, client: client, capabilities: capabilities)
        await app.refreshSetUp()
        #expect(app.projects.map(\.isSetUp) == [false])
    }
}

/// A counter a main-actor callback can bump.
@MainActor final class Count {
    var value = 0
}
