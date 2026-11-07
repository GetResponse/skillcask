import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskUI

/// Settings (S14): the environment table reaching new runs and path resolution, config.toml's path, the
/// skills.sh write, and the GitHub token's rules (stdin only, never kept, never in a message).
@Suite(.serialized) @MainActor struct SettingsTests {
    static let capabilities = Capabilities(version: Capabilities.minimum)
    static let secret = "ghp_S3cretTokenThatMustNeverLeak0123456789"

    static func settings() -> SettingsStore {
        let name = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return SettingsStore(defaults: defaults)
    }

    static func variable(_ name: String, _ value: String) -> SettingsStore.EnvironmentVariable {
        SettingsStore.EnvironmentVariable(name: name, value: value)
    }

    // MARK: - Environment

    /// A fake `skillcask` in a temporary folder: `--version` passes the gate, anything else prints its environment.
    static func envScript() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SettingsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "skillcask")
        let text = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"skillcask 0.9.4 (fake)\"; else env; fi\n"
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    static func environment(of result: RunResult) -> [String: String] {
        Dictionary(
            result.stdoutText.split(separator: "\n")
                .compactMap { line -> (String, String)? in
                    guard let eq = line.firstIndex(of: "=") else { return nil }
                    return (String(line[..<eq]), String(line[line.index(after: eq)...]))
                }, uniquingKeysWith: { first, _ in first })
    }

    /// The live client (`ProcessRunner` over the app's `EnvironmentSource`) gives every run started after a table
    /// edit the new values, without a new client; refused names never reach the child.
    @Test func tableEditsReachTheNextRunOfTheLiveClient() async throws {
        let script = try Self.envScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let settings = Self.settings()
        settings.environmentVariables = [Self.variable("SETTINGS_TEST_A", "1")]
        let app = AppStore(
            settings: settings, locator: Locator(bundled: script), manifestExists: { _ in true })
        await app.boot()
        let context = try #require(app.cliContext)
        let status = try Invocation(.status, in: .project(at: "/tmp"), capabilities: context.capabilities)
        let first = Self.environment(of: try await context.client.run(status))
        #expect(first["SETTINGS_TEST_A"] == "1")

        app.setEnvironmentVariables([
            Self.variable("SETTINGS_TEST_A", "2"), Self.variable("SETTINGS_TEST_B", "b"),
            Self.variable("GITHUB_TOKEN", Self.secret), Self.variable("SKILLCASK_AGENT", "1"),
        ])
        let second = Self.environment(of: try await context.client.run(status))
        #expect(second["SETTINGS_TEST_A"] == "2" && second["SETTINGS_TEST_B"] == "b")
        #expect(second["GITHUB_TOKEN"] != Self.secret)
        #expect(second["SKILLCASK_AGENT"] == "0")

        app.setEnvironmentVariables([])
        let third = Self.environment(of: try await context.client.run(status))
        #expect(third["SETTINGS_TEST_A"] == nil && third["SETTINGS_TEST_B"] == nil)
    }

    /// Reveal skills.toml and Open config.toml resolve in the children's environment, which the table can never
    /// redirect.
    @Test func revealAndConfigPathsIgnoreRefusedRows() {
        let app = AppStore(settings: Self.settings(), client: FakeCLIClient(), capabilities: Self.capabilities)
        let base = ["HOME": "/Users/me"]
        #expect(app.manifest(of: .personal, base: base).path == "/Users/me/.config/skillcask/skills.toml")
        #expect(app.configFile(base: base).path == "/Users/me/.config/skillcask/config.toml")
        #expect(
            app.configFile(base: ["HOME": "/Users/me", "XDG_CONFIG_HOME": "/x"]).path == "/x/skillcask/config.toml")
        #expect(app.configFile(base: ["HOME": "/Users/me", "SKILLCASK_HOME": "/s"]).path == "/s/config.toml")
        // The table cannot move them: SKILLCASK_HOME and XDG_CONFIG_HOME would move config.toml (policy) and auth.json.
        app.setEnvironmentVariables([Self.variable("SKILLCASK_HOME", "/s"), Self.variable("XDG_CONFIG_HOME", "/x")])
        #expect(app.manifest(of: .personal, base: base).path == "/Users/me/.config/skillcask/skills.toml")
        #expect(app.configFile(base: base).path == "/Users/me/.config/skillcask/config.toml")
        #expect(app.environment.overrides.isEmpty)
    }

    /// The table saved in Settings applies from launch, on top of the policy the app was given.
    @Test func savedTableAppliesAtLaunch() {
        let settings = Self.settings()
        settings.environmentVariables = [Self.variable("HTTPS_PROXY", "http://p:3128"), Self.variable("PATH", "/x")]
        let app = AppStore(
            settings: settings, client: FakeCLIClient(), capabilities: Self.capabilities,
            environment: EnvironmentPolicy(extraPaths: [], overrides: ["KEEP": "1"]))
        #expect(app.environment.overrides == ["KEEP": "1", "HTTPS_PROXY": "http://p:3128"])
    }

    static func context(_ client: FakeCLIClient) -> CLISettingsStore.Context {
        CLISettingsStore.Context(client: client, capabilities: capabilities)
    }

    // MARK: - GitHub token

    static let authSet = Invocation.Command.authSet(
        host: CLISettingsStore.gitHubHost, username: CLISettingsStore.gitHubUsername)

    /// The token is the run's stdin and nothing else: not in argv, not in the displayed command, not in the
    /// environment the app gives children; the store keeps no copy afterwards.
    @Test func signInPassesTheTokenOnlyThroughStdin() async throws {
        let client = FakeCLIClient()
        await client.lines(Self.authSet, in: .personal, [])
        let store = CLISettingsStore()
        let stored = await store.signIn(token: "  \(Self.secret)\n", in: Self.context(client))
        #expect(stored && store.gitHub == .signedIn && store.gitHubFailure == nil && !store.isChangingToken)
        let invocation = try #require(await client.invocations.first)
        #expect(invocation.argv == ["auth", "set", "--username", "oauth2", "--", "api.github.com"])
        #expect(invocation.stdin == .text(Self.secret))
        #expect(!invocation.argv.contains { $0.contains(Self.secret) })
        #expect(!invocation.displayCommand.contains(Self.secret))
        #expect(!String(describing: invocation).contains(Self.secret))
        let app = AppStore(settings: Self.settings(), client: client, capabilities: Self.capabilities)
        #expect(!app.environment.environment(from: [:]).values.contains { $0.contains(Self.secret) })
        var dumped = ""
        dump(store, to: &dumped)
        #expect(!dumped.contains(Self.secret))
    }

    /// A failure's message never carries the token, even if the CLI's error echoed it, and drops the transcript.
    @Test func signInFailureNeverShowsTheToken() async {
        let client = FakeCLIClient()
        await client.script(
            Self.authSet, in: .personal,
            .error(
                .failed(
                    code: .signIn, message: "helper refused \(Self.secret)", hint: "check \(Self.secret)",
                    stderr: "error: \(Self.secret)")))
        let store = CLISettingsStore()
        let stored = await store.signIn(token: Self.secret, in: Self.context(client))
        #expect(!stored && store.gitHub == .unknown)
        let failure = store.gitHubFailure
        #expect(failure?.title == SettingsCopy.couldNotSignIn && failure?.details == nil)
        let texts = [failure?.title, failure?.reason, failure?.action, failure?.details, failure?.monoFragment]
        #expect(!texts.compactMap { $0 }.contains { $0.contains(Self.secret) })
        var dumped = ""
        dump(store, to: &dumped)
        #expect(!dumped.contains(Self.secret))
    }

    /// An empty or blank token runs nothing.
    @Test func blankTokenRunsNothing() async {
        let client = FakeCLIClient()
        let store = CLISettingsStore()
        #expect(await !store.signIn(token: " \n", in: Self.context(client)))
        #expect(await client.invocations.isEmpty)
    }

    /// Sign Out removes the same credential: `auth remove --username oauth2 -- api.github.com`, no `-g`.
    @Test func signOutRemovesTheOAuthCredential() async throws {
        let client = FakeCLIClient()
        let remove = Invocation.Command.authRemove(
            host: CLISettingsStore.gitHubHost, username: CLISettingsStore.gitHubUsername)
        await client.lines(remove, in: .personal, [])
        let store = CLISettingsStore()
        await store.signOut(in: Self.context(client))
        #expect(store.gitHub == .signedOut)
        #expect(
            await client.invocations.first?.argv == ["auth", "remove", "--username", "oauth2", "--", "api.github.com"])
        #expect(await client.invocations.first?.stdin == .null)
    }

    /// The CLI's confirmation decides the wording: the Keychain only for osxkeychain; the plain-text helper
    /// warning is kept, masked.
    @Test(arguments: [
        ("stored a 40-character token for api.github.com with git's credential helper (osxkeychain)\n", true),
        ("stored a 40-character token for api.github.com with git's credential helper (store)\n", false),
    ])
    func signInReportsWhereTheTokenWent(stdout: String, keychain: Bool) async {
        let client = FakeCLIClient()
        await client.script(Self.authSet, in: .personal, .result(stdout: stdout, exit: 0, lines: []))
        let store = CLISettingsStore()
        await store.signIn(token: Self.secret, in: Self.context(client))
        #expect(store.tokenStorage == (keychain ? .keychain : .otherHelper))
        #expect(store.gitHub == .signedIn)
    }

    /// The `store` helper's warning reaches the view, with the token masked if a helper ever echoed it.
    @Test func helperWarningsAreKeptMasked() {
        #expect(CLISettingsStore.mask(Self.secret, in: "helper said \(Self.secret)") == "helper said ••••")
    }

    // MARK: - Persistence of the table

    /// Every value written to the suite for `name`.
    static func storedValues(_ defaults: UserDefaults, name: String) -> [String] {
        ((defaults.array(forKey: SettingsStore.Key.environmentVariables) as? [[String: String]]) ?? [])
            .filter { $0["name"] == name }.compactMap { $0["value"] }.filter { !$0.isEmpty }
    }

    /// A refused name never reaches disk with its value, typed in either order, keystroke by keystroke; the value
    /// stays in memory for the row.
    @Test(arguments: [
        "GITHUB_TOKEN", "GH_TOKEN", "COMPOSER_AUTH", "SKILLCASK_GITHUB_API", "SKILLCASK_MIN_RELEASE_AGE",
        "DYLD_INSERT_LIBRARIES", "GIT_ASKPASS",
    ])
    func refusedRowsNeverPersistAValue(name: String) {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        func everythingStored() -> [String] {
            ((defaults.array(forKey: SettingsStore.Key.environmentVariables) as? [[String: String]]) ?? [])
                .compactMap { $0["value"] }
        }
        // Value first, then the name one keystroke at a time.
        var row = SettingsStore.EnvironmentVariable(name: "", value: Self.secret)
        settings.environmentVariables = [row]
        #expect(!everythingStored().contains(Self.secret))
        for end in name.indices {
            row.name = String(name[...end])
            settings.environmentVariables = [row]
            #expect(!everythingStored().contains(Self.secret), "stored at \(row.name)")
        }
        // Name first, then the value one keystroke at a time.
        var second = SettingsStore.EnvironmentVariable(name: name, value: "")
        for end in Self.secret.indices {
            second.value = String(Self.secret[...end])
            settings.environmentVariables = [row, second]
            #expect(Self.storedValues(defaults, name: name).isEmpty)
        }
        #expect(settings.environmentVariables.last?.value == Self.secret)
        #expect(SettingsStore(defaults: defaults).environmentVariables.allSatisfy { $0.value.isEmpty })
        #expect(settings.environmentOverrides[name] == nil)
    }

    /// A URL with credentials applies this session but is never written; an allowed plain value is.
    @Test func credentialedValuesApplyButAreNotSaved() {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.environmentVariables = [
            Self.variable("HTTPS_PROXY", "http://me:pa55@proxy.example:3128"),
            Self.variable("NO_PROXY", "localhost"),
        ]
        settings.commitEnvironmentValues()
        #expect(settings.environmentVariables[0].hasCredentials)
        #expect(settings.environmentOverrides["HTTPS_PROXY"] == "http://me:pa55@proxy.example:3128")
        #expect(Self.storedValues(defaults, name: "HTTPS_PROXY").isEmpty)
        #expect(Self.storedValues(defaults, name: "NO_PROXY") == ["localhost"])
    }

    /// A token-shaped value is never saved, whatever the row's name; it applies this session only.
    @Test(arguments: ["ghp_abcDEF123456", "github_pat_11AB_cd", "glpat-xYz_1", "gho_1", "ghs_1", "ghu_1", "ghr_1"])
    func tokenShapedValuesAreNotSaved(value: String) {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.environmentVariables = [Self.variable("MY_SETTING", value)]
        #expect(settings.environmentVariables[0].hasCredentials)
        #expect(Self.storedValues(defaults, name: "MY_SETTING").isEmpty)
        #expect(settings.environmentOverrides["MY_SETTING"] == value)
    }

    /// Values reach disk only on commit: typed keystroke by keystroke, a partial `http://me:pa55` (no `@` yet, so
    /// not yet recognisable as credentials) is never written; names are saved as typed.
    @Test func valuesAreSavedOnlyOnCommit() {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        var row = Self.variable("HTTPS_PROXY", "")
        let secret = "http://me:pa55@proxy.example:3128"
        for end in secret.indices {
            row.value = String(secret[...end])
            settings.environmentVariables = [row]
            #expect(Self.storedValues(defaults, name: "HTTPS_PROXY").isEmpty, "stored at \(row.value)")
        }
        #expect(SettingsStore(defaults: defaults).environmentVariables.map(\.name) == ["HTTPS_PROXY"])
        settings.commitEnvironmentValues()
        #expect(Self.storedValues(defaults, name: "HTTPS_PROXY").isEmpty, "credentials are never saved")
        // A plain value: still nothing while typing, saved at the commit.
        row.value = "http://proxy.example:3128"
        settings.environmentVariables = [row]
        #expect(Self.storedValues(defaults, name: "HTTPS_PROXY").isEmpty)
        settings.commitEnvironmentValues()
        #expect(Self.storedValues(defaults, name: "HTTPS_PROXY") == ["http://proxy.example:3128"])
        // Editing again keeps the committed value on disk until the next commit.
        row.value = "http://me:pa"
        settings.environmentVariables = [row]
        #expect(Self.storedValues(defaults, name: "HTTPS_PROXY") == ["http://proxy.example:3128"])
        #expect(settings.environmentOverrides["HTTPS_PROXY"] == "http://me:pa")
    }

    /// Removing a table row restores a base override of the same name instead of wiping it.
    @Test func tableEditsKeepTheBaseOverrides() {
        let app = AppStore(
            settings: Self.settings(), client: FakeCLIClient(), capabilities: Self.capabilities,
            environment: EnvironmentPolicy(extraPaths: [], overrides: ["HTTPS_PROXY": "http://base:1"]))
        app.setEnvironmentVariables([Self.variable("HTTPS_PROXY", "http://table:2")])
        #expect(app.environment.overrides["HTTPS_PROXY"] == "http://table:2")
        app.setEnvironmentVariables([])
        #expect(app.environment.overrides == ["HTTPS_PROXY": "http://base:1"])
    }

    // MARK: - Choose…

    /// Choose… (and Locate…) rebuild the scope stores: a visited scope's next command runs on the chosen tool.
    @Test func chosenToolServesVisitedScopes() async throws {
        let first = FakeCLIClient()
        await first.script(.version, in: .personal, .result(stdout: "skillcask 0.9.4 (a)\n", exit: 0, lines: []))
        let chosen = FakeCLIClient()
        await chosen.script(.version, in: .personal, .result(stdout: "skillcask 0.9.5 (b)\n", exit: 0, lines: []))
        let chosenURL = URL(fileURLWithPath: "/chosen/skillcask")
        let app = AppStore(
            settings: Self.settings(), locator: Locator(bundled: URL(fileURLWithPath: "/fake/skillcask")) { _ in true }
        ) {
            $0 == chosenURL ? chosen : first
        }
        await app.boot()
        let before = try #require(app.store(for: .personal))
        #expect(before.client as? FakeCLIClient === first)
        #expect(await app.locate(executable: chosenURL) == nil)
        let after = try #require(app.store(for: .personal))
        #expect(after !== before && after.client as? FakeCLIClient === chosen)
        await after.refresh()
        #expect(await chosen.commands.contains(.status))
        #expect(await !first.commands.contains(.status))
    }

    /// "Use the detected one" does nothing while a detection runs.
    @Test func useDetectedIsGuardedByARunningDetection() async {
        let gate = Gate()
        let client = FakeCLIClient()
        await client.script(
            .version, in: .personal, .result(stdout: "skillcask 0.9.4 (a)\n", exit: 0, lines: []), gate: gate)
        let settings = Self.settings()
        settings.binaryPath = "/chosen/skillcask"
        let app = AppStore(settings: settings, locator: Locator(bundled: nil) { _ in true }) { _ in client }
        let locating = Task { await app.locate(executable: URL(fileURLWithPath: "/other/skillcask")) }
        await gate.arrived()
        await app.useDetectedBinary()
        #expect(settings.binaryPath == "/chosen/skillcask")
        await gate.open()
        _ = await locating.value
    }

    /// Regression: when detection then found nothing, Settings still named the binary just forgotten.
    @Test func useDetectedForgetsTheChosenBinary() async {
        let client = FakeCLIClient()
        await client.script(.version, in: .personal, .result(stdout: "skillcask 0.9.4 (a)\n", exit: 0, lines: []))
        let chosen = URL(fileURLWithPath: "/chosen/skillcask")
        let locator = Locator(path: nil, bundled: nil) { $0 == chosen }
        let app = AppStore(settings: Self.settings(), locator: locator) { _ in client }
        #expect(await app.locate(executable: chosen) == nil)
        #expect(app.binary == .configured(chosen))
        await app.useDetectedBinary()
        #expect(app.binary == nil)
    }

    // MARK: - Copy

    @Test func sourcesSentenceNamesTheProjectsOwnSources() {
        #expect(SettingsCopy.projectSources(DesignFixtures.api.repositories) == ["acme"])
        #expect(
            SettingsCopy.sourcesSearched(["acme"], project: "api")
                == "Packagist, plus the sources of the open project (acme for api). GitHub results appear only "
                + "where policy allows them.")
        #expect(!SettingsCopy.sourcesSearched([], project: "api").contains("("))
        #expect(SettingsCopy.adoptedSummary(folders: 1, bytes: 0).hasPrefix("1 folder ·"))
    }
}
