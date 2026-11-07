import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskUI

/// Settings › Global through `skillcask -g config` (D48): the list is read with `--json`, each change is one
/// `config` run followed by a read, and a refusal stays under its key with `allow-sources` values masked.
@Suite @MainActor struct GlobalSettingsTests {
    let client = FakeCLIClient()
    let capabilities = Capabilities(version: Capabilities.minimum)
    static let list = #"""
        {"file":"/Users/me/.config/skillcask/config.toml","settings":{"agents.targets":{"from":"config.toml",\#
        "value":["claude"]},"policy.min-release-age":{"from":"default","value":"72h"},\#
        "search.skills-sh":{"from":null,"value":null}}}
        """#

    func context() -> CLISettingsStore.Context {
        CLISettingsStore.Context(client: client, capabilities: capabilities)
    }

    func store() -> CLISettingsStore {
        CLISettingsStore()
    }

    @Test func loadReadsTheWholeList() async throws {
        await client.json(.configList, in: .personal, Self.list)
        let store = store()
        await store.loadGlobalSettings(in: context())
        #expect(store.globalSettings?.orderedKeys == ["policy.min-release-age", "agents.targets", "search.skills-sh"])
        #expect(store.globalSettingsFailure == nil)
        #expect(await client.invocations.map(\.argv) == [["-g", "config", "--json"]])
    }

    /// A broken config.toml: `config --json` exits 1 without a document.
    @Test func aBrokenFileSaysSo() async {
        let broken = CLIError.failed(
            code: .problem,
            message:
                "/Users/me/.config/skillcask/config.toml: only [policy], [agents] and [search] are read here, found nonsense",
            hint: nil, stderr: "")
        await client.script(.configList, in: .personal, .error(broken))
        let store = store()
        await store.loadGlobalSettings(in: context())
        #expect(store.globalSettings == nil)
        #expect(store.globalSettingsFailure?.title == SettingsCopy.couldNotReadGlobal)
        #expect(store.globalSettingsFailure?.details == nil)
    }

    /// One `config` run, then the list again; a list key gets one argument per entry.
    @Test func setAndUnsetReadTheListAgain() async throws {
        let set = Invocation.Command.configSet(key: "agents.targets", values: ["claude", "codex"])
        await client.lines(set, in: .personal, ["set agents.targets in /Users/me/.config/skillcask/config.toml"])
        await client.json(.configList, in: .personal, Self.list)
        await client.lines(.configUnset(key: "agents.targets"), in: .personal, [])
        await client.json(.configList, in: .personal, Self.list)
        let store = store()
        #expect(await store.setGlobal("agents.targets", values: ["claude", "codex"], in: context()))
        #expect(await store.unsetGlobal("agents.targets", in: context()))
        #expect(store.settingRefusal == nil && store.changingSetting == nil && store.globalSettings != nil)
        #expect(
            await client.invocations.map(\.argv) == [
                ["-g", "config", "--", "agents.targets", "claude", "codex"], ["-g", "config", "--json"],
                ["-g", "config", "--unset", "--", "agents.targets"], ["-g", "config", "--json"],
            ])
    }

    /// The skills.sh key is also Settings › Search's switch: its state is read again too.
    @Test func changingSkillsShRefreshesTheSearchSwitch() async {
        await client.lines(.configSet(key: "search.skills-sh", values: ["true"]), in: .personal, [])
        await client.json(.configList, in: .personal, Self.list)
        await client.json(
            .config(key: CLISettingsStore.skillsShKey), in: .personal, #"{"from":"config.toml","value":true}"#)
        let store = store()
        await store.setGlobal("search.skills-sh", values: ["true"], in: context())
        #expect(store.skillsSh == .on)
    }

    /// The CLI quotes a rejected `allow-sources` entry as typed (`Fixtures/0.9.4/config.refused-source.stderr`):
    /// the refusal kept under the key shows it as the CLI prints URLs elsewhere.
    @Test func aRefusalStaysUnderItsKeyMasked() async throws {
        let typed = "http://user:tok@bad.example"
        let refused = CLIError.failed(
            code: .problem,
            message: #"/Users/me/.config/skillcask/config.toml: policy.allow-sources "\#(typed)" is not packagist, "#
                + "github, an https:// URL prefix or a repository name",
            hint: nil, stderr: "error: …\(typed)…")
        await client.script(.configSet(key: "policy.allow-sources", values: [typed]), in: .personal, .error(refused))
        await client.json(.configList, in: .personal, Self.list)
        let store = store()
        #expect(await !store.setGlobal("policy.allow-sources", values: [typed], in: context()))
        let refusal = try #require(store.settingRefusal)
        #expect(refusal.key == "policy.allow-sources")
        #expect(refusal.message.title == SettingsCopy.couldNotChange("policy.allow-sources"))
        let shown = [refusal.message.title, refusal.message.reason, refusal.message.action, refusal.message.details]
            .compactMap { $0 }.joined(separator: "\n")
        #expect(!shown.contains("tok") && shown.contains("http://••••@bad.example"))
    }

    /// A read cancelled with the pane keeps what was there; a slow earlier read cannot overwrite a later one.
    @Test func onlyTheNewestReadCounts() async throws {
        let old = #"{"file":"/old","settings":{}}"#
        let new = #"{"file":"/new","settings":{}}"#
        let slow = Gate()
        await client.json(.configList, in: .personal, old, gate: slow)
        await client.json(.configList, in: .personal, new)
        let store = store()
        let first = Task { await store.loadGlobalSettings(in: context()) }
        await slow.arrived()
        await store.loadGlobalSettings(in: context())
        #expect(store.globalSettings?.file == "/new")
        await slow.open()
        await first.value
        #expect(store.globalSettings?.file == "/new", "the earlier read finished last and was dropped")
        await client.script(.configList, in: .personal, .error(.cancelled))
        await store.loadGlobalSettings(in: context())
        #expect(store.globalSettings?.file == "/new" && store.globalSettingsFailure == nil)
    }

    /// One config write at a time across the Search switch and Global: a second write while one runs does nothing.
    @Test func configWritesNeverOverlap() async throws {
        let held = Gate()
        await client.lines(.configSet(key: "agents.targets", values: ["claude"]), in: .personal, [], gate: held)
        await client.json(.configList, in: .personal, Self.list)
        let store = store()
        let first = Task { await store.setGlobal("agents.targets", values: ["claude"], in: context()) }
        await held.arrived()
        #expect(store.isWritingConfig)
        await store.setSkillsSh(true, in: context())
        #expect(await !store.setGlobal("policy.packagist", values: ["false"], in: context()))
        await held.open()
        #expect(await first.value)
        #expect(!store.isWritingConfig)
        #expect(
            await client.invocations.map(\.argv) == [
                ["-g", "config", "--", "agents.targets", "claude"], ["-g", "config", "--json"],
            ])
    }

    // MARK: - The pane's rules

    @Test func valuesFromTheDraft() {
        #expect(GlobalPane.values(of: " claude, ,codex ,", .list) == ["claude", "codex"])
        #expect(GlobalPane.values(of: "  3d ", .text) == ["3d"])
        #expect(GlobalPane.values(of: " , ", .list).isEmpty && GlobalPane.values(of: "  ", .text).isEmpty)
        #expect(GlobalPane.draft(of: .array([.string("claude"), .string("codex")])) == "claude, codex")
        #expect(GlobalPane.draft(of: .null).isEmpty && GlobalPane.shown(.null) == SettingsCopy.notSet)
    }

    /// Read-only: a key the environment sets, and `allow-sources` with a URL (shown redacted). Enforced stays
    /// editable: with `-g`, config.toml is the user's own file.
    @Test func readOnlyRows() {
        let environment = ConfigValueDocument(value: .bool(false), from: "environment")
        #expect(
            GlobalPane.readOnlyReason("policy.allow-ranges", environment)
                == SettingsCopy.environmentNote(variable: "SKILLCASK_ALLOW_RANGES"))
        let url = ConfigValueDocument(
            value: .array([.string("packagist"), .string("https://r.example/")]), from: "config.toml")
        #expect(GlobalPane.readOnlyReason("policy.allow-sources", url) == SettingsCopy.redactedSourcesNote)
        let names = ConfigValueDocument(value: .array([.string("packagist"), .string("github")]), from: "config.toml")
        #expect(GlobalPane.readOnlyReason("policy.allow-sources", names) == nil)
        let enforced = ConfigValueDocument(value: .string("72h"), from: "config.toml, enforced")
        #expect(GlobalPane.readOnlyReason("policy.min-release-age", enforced) == nil)
        let system = ConfigValueDocument(value: .string("72h"), from: "system config.toml")
        #expect(GlobalPane.readOnlyReason("policy.min-release-age", system) == nil)
        let systemList = ConfigValueDocument(value: .array([.string("allow-sources")]), from: "system config.toml")
        #expect(GlobalPane.readOnlyReason("policy.enforce", systemList) == SettingsCopy.systemEnforcedNote)
        let organisation = ConfigValueDocument(value: .string("72h"), from: "system config.toml, enforced")
        #expect(GlobalPane.readOnlyReason("policy.min-release-age", organisation) == SettingsCopy.systemEnforcedNote)
    }

    /// Unset only where config.toml sets the key and does not enforce it: the CLI refuses `--unset` of a key
    /// `policy.enforce` lists (`Fixtures/0.9.4/config.refused-unset-enforced.stderr`).
    @Test func unsetIsOfferedOnlyWhereTheCLITakesIt() {
        let offered = [ConfigLayer.configFile, .enforced, .system, .systemEnforced, .builtIn, .environment]
            .filter {
                GlobalPane.canUnset($0)
            }
        #expect(offered == [ConfigLayer.configFile])
        #expect(!GlobalPane.canUnset(nil))
    }
}
