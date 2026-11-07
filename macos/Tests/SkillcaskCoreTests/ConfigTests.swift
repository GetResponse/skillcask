import Foundation
import Testing

@testable import SkillcaskCore

/// `-g config --json` and its refusals as 0.9.4 prints them (`Fixtures/0.9.4`, README there).
@Suite struct ConfigTests {
    static let directory = "0.9.4"
    let capabilities = Capabilities(version: Capabilities.minimum)

    func list(_ name: String) throws -> ConfigListDocument {
        try Fixture.decode(ConfigListDocument.self, Self.directory, name)
    }

    @Test func aFreshConfigListsEveryKeyInTheCLIsOrder() throws {
        let document = try list("config.empty")
        #expect(document.file == "/Users/me/.config/skillcask/config.toml")
        // 0.9.4 predates `policy.deny-packages` (D57).
        #expect(document.orderedKeys == ConfigKey.order.filter { $0 != "policy.deny-packages" })
        #expect(
            document.settings["policy.min-release-age"] == ConfigValueDocument(value: .string("72h"), from: "default"))
        #expect(document.settings["policy.min-release-age"]?.layer == .builtIn)
        #expect(document.settings["agents.targets"]?.value == .array([.string("claude")]))
        let skillsSh = try #require(document.settings["search.skills-sh"])
        #expect(skillsSh.layer == nil && skillsSh.value == .null)
    }

    @Test func layersOfAFileThatSetsAndEnforces() throws {
        let document = try list("config.set")
        // `3d` was set: the CLI prints the duration it read.
        #expect(
            document.settings["policy.min-release-age"]
                == ConfigValueDocument(value: .string("72h"), from: "config.toml, enforced"))
        #expect(document.settings["policy.min-release-age"]?.layer == .enforced)
        #expect(document.settings["policy.enforce"]?.layer == .configFile)
        #expect(document.settings["search.skills-sh"]?.value == .bool(false))
        #expect(ConfigLayer.enforced.isConfigFile && ConfigLayer.configFile.isConfigFile)
        #expect(!ConfigLayer.builtIn.isConfigFile && !ConfigLayer.environment.isConfigFile)
        let environment = try list("config.environment")
        #expect(
            environment.settings["policy.allow-ranges"] == ConfigValueDocument(value: .bool(false), from: "environment")
        )
        #expect(ConfigLayer("skills.toml") == .manifest && ConfigLayer("later") == .other("later"))
    }

    /// D60's machine-wide file: its own layers, neither of them the user's config.toml (no Unset).
    @Test func systemLayers() {
        #expect(ConfigLayer("system config.toml") == .system)
        #expect(ConfigLayer("system config.toml, enforced") == .systemEnforced)
        #expect(!ConfigLayer.system.isConfigFile && !ConfigLayer.systemEnforced.isConfigFile)
    }

    /// A key a newer CLI adds follows the known ones, by name, and is edited by the type of its value.
    @Test func unknownKeysFollowByName() throws {
        let synthetic = #"""
            {"file":"/c","settings":{"zeta.x":{"from":"default","value":[]},"alpha.y":{"from":null,"value":null},\#
            "policy.packagist":{"from":"default","value":true}}}
            """#
        let document = try JSONDecoder().decode(ConfigListDocument.self, from: Data(synthetic.utf8))
        #expect(document.orderedKeys == ["policy.packagist", "alpha.y", "zeta.x"])
        #expect(ConfigKey.kind(of: "zeta.x", value: .array([])) == .list)
        #expect(ConfigKey.kind(of: "alpha.y", value: .null) == .text)
        #expect(ConfigKey.kind(of: "search.skills-sh", value: .null) == .bool)
        #expect(ConfigKey.kind(of: "policy.enforce", value: .null) == .list)
        #expect(ConfigKey.kind(of: "policy.min-release-age", value: .string("72h")) == .text)
    }

    /// `policy::env_layer`'s names; only the `policy.*` keys of `policy::KEYS` have one.
    @Test func environmentVariables() {
        #expect(ConfigKey.environmentVariable(for: "policy.min-release-age") == "SKILLCASK_MIN_RELEASE_AGE")
        #expect(ConfigKey.environmentVariable(for: "policy.allow-sources") == "SKILLCASK_ALLOW_SOURCES")
        #expect(ConfigKey.environmentVariable(for: "policy.deny-packages") == "SKILLCASK_DENY_PACKAGES")
        #expect(ConfigKey.kind(of: "policy.deny-packages", value: .null) == .list)
        #expect(ConfigKey.environmentVariable(for: "policy.enforce") == nil)
        #expect(ConfigKey.environmentVariable(for: "search.skills-sh") == nil)
        #expect(ConfigKey.mayHoldCredentials("policy.allow-sources") && !ConfigKey.mayHoldCredentials("agents.targets"))
    }

    /// The app redacts as the CLI does: what was set as `https://user:tok@repo.example/p?x=1` comes back as the
    /// CLI printed it.
    @Test func redactionMatchesTheCLI() throws {
        let printed = try list("config.set").settings["policy.allow-sources"]?.value
        #expect(
            printed == .array([.string("packagist"), .string(Redaction.url("https://user:tok@repo.example/p?x=1"))]))
        #expect(Redaction.url("https://user:tok@repo.example/p?x=1") == "https://repo.example/p?%E2%80%A6")
        #expect(Redaction.url("http://user:tok@bad.example") == "http://bad.example")
        #expect(Redaction.url("packagist") == "packagist")
        #expect(Redaction.url("https://repo.example/p/") == "https://repo.example/p/")
    }

    /// Masking by pattern, for text the CLI quotes as typed: any `scheme://user[:password]@` and `user[:password]@`,
    /// and each typed value also in its Rust `{:?}` form (`\"`, `\\`) with its query.
    @Test func credentialsAreMaskedByPatternAndAsTyped() {
        #expect(Redaction.credentials(in: "ftp://u:p@h ost/") == "ftp://••••@h ost/")
        #expect(Redaction.credentials(in: "see u:p@h.example/x now") == "see ••••@h.example/x now")
        let plain = "https://repo.example/p/ and packagist"
        #expect(Redaction.credentials(in: plain) == plain)
        let typed = #"https://u:p@h.example/a"b?t=1"#
        let message = #"policy.allow-sources "https://u:p@h.example/a\"b?t=1" is not packagist"#
        let masked = Redaction.credentials(in: message, typed: [typed])
        #expect(masked == #"policy.allow-sources "https://••••@h.example/a"b?…" is not packagist"#)
        let slash = #"https://u:p@h.example/a\b"#
        let quoted = #""https://u:p@h.example/a\\b" is not packagist"#
        #expect(!Redaction.credentials(in: quoted, typed: [slash]).contains("u:p"))
        let real =
            "/Users/me/.config/skillcask/config.toml: policy.allow-sources \"http://user:tok@bad.example\" "
            + "is not packagist, github, an https:// URL prefix or a repository name"
        #expect(!Redaction.credentials(in: real, typed: ["http://user:tok@bad.example"]).contains("tok"))
    }

    /// Refusals as 0.9.4 prints them: exit 1 (`problem`), one `error:` line, a hint only for an unknown key.
    @Test(arguments: [
        (
            "config.refused-unset-enforced",
            "/Users/me/.config/skillcask/config.toml: policy.enforce lists min-release-age, which policy does not set",
            false
        ),
        ("config.unknown-key", #"unknown key "policy.nope""#, true),
        (
            "config.broken",
            "/Users/me/.config/skillcask/config.toml: only [policy], [agents] and [search] are read here, found nonsense",
            false
        ),
    ])
    func refusals(name: String, message: String, hasHint: Bool) throws {
        let stderr = try Fixture.text(Self.directory, "\(name).stderr")
        let invocation = try Invocation(.configList, in: .personal, capabilities: capabilities)
        let result = RunResult(invocation: invocation, status: .exited(1), stdout: Data(), stderr: stderr)
        guard case .failed(let code, let text, let hint, _)? = result.failure() else {
            Issue.record("no failure for \(name)")
            return
        }
        #expect(code == .problem && text == message && (hint != nil) == hasHint)
        #expect(throws: CLIError.self) { try result.document(ConfigListDocument.self) }
    }
}
