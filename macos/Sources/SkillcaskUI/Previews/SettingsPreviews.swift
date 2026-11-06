import SkillcaskCore
import SwiftUI

extension PreviewRegistry {
    /// Each Settings tab as its pane at the board's 600 pt width over the fixture stores (api open). The
    /// toolbar tabs are the system Settings window's own chrome and are not drawn here. States: `general` (the board,
    /// tool found automatically), `generalChosen` (a tool picked with Choose…, with "Use the detected one"),
    /// `search` (skills.sh on in config.toml, acme for api), `searchNotSet` (config.toml without the key),
    /// `updatesUnknown` (at launch: no command tells whether a token is stored), `updatesSignedOut` (the board, after
    /// Sign Out), `tokenEntry` (a token typed, drawn as dots), `updatesSignedIn` (after a Save the CLI stored with osxkeychain), `updatesSignedInPlainText` (stored by the
    /// `store` helper, its warning kept), `signInFailed`,
    /// `advanced` (the board's two variables), `advancedRefused` (a GITHUB_TOKEN row the policy refuses) and
    /// `advancedEmpty`; Global (no board, every state invented): `globalList` (config.toml sets the agents, the
    /// minimum release age and skills.sh), `globalEditing` (the agents list being edited), `globalEnforced` (an
    /// enforced key, one the environment sets and `allow-sources` with a URL, both read-only), `globalRefusal` (the
    /// CLI refusing an agent name it does not know). Declared: the environment table is the native `Table` (system header chrome, not the
    /// board's `--win` header) with a 200 pt Name column where the board draws 220; credentialed values show
    /// masked until edited.
    static let settings: [Entry] = [
        entry("general", height: 330) { SettingsSample(tab: .general) },
        entry("generalChosen", height: 330) { SettingsSample(tab: .general, configured: true) },
        // A sheet is open in the main window: Choose… and "Use the detected one" are disabled, the caption says why.
        entry("generalSheetOpen", height: 360) { SettingsSample(tab: .general, configured: true, sheetOpen: true) },
        entry("search", height: 300) { SettingsSample(tab: .search) },
        entry("searchNotSet", height: 300) { SettingsSample(tab: .search, skillsSh: .notSet) },
        entry("updatesUnknown", height: 400) { SettingsSample(tab: .updates) },
        entry("updatesSignedOut", height: 400) { SettingsSample(tab: .updates, gitHub: .signedOut) },
        entry("tokenEntry", height: 400) {
            SettingsSample(tab: .updates, gitHub: .signedOut, token: "ghp_exampleExampleExample0000")
        },
        entry("updatesSignedIn", height: 260) {
            SettingsSample(tab: .updates, gitHub: .signedIn, tokenStorage: .keychain)
        },
        entry("updatesSignedInPlainText", height: 300) {
            SettingsSample(
                tab: .updates, gitHub: .signedIn, tokenStorage: .otherHelper,
                tokenWarnings: ["git's credential helper `store` keeps the token in plain text in ~/.git-credentials"])
        },
        entry("signInFailed", height: 420) {
            SettingsSample(
                tab: .updates, gitHub: .unknown,
                failure: ErrorCopy.message(
                    for: .failed(
                        code: .signIn, message: "git has no credential helper", hint: nil, stderr: ""),
                    title: SettingsCopy.couldNotSignIn))
        },
        entry("advanced", height: 440) { SettingsSample(tab: .advanced) },
        entry("advancedRefused", height: 580) {
            SettingsSample(
                tab: .advanced,
                variables: SettingsSample.boardVariables + [
                    SettingsStore.EnvironmentVariable(name: "GITHUB_TOKEN", value: "…"),
                    SettingsStore.EnvironmentVariable(
                        name: "HTTP_PROXY", value: "http://me:pw@proxy.acme.example:3128"),
                ])
        },
        entry("advancedEmpty", height: 400) { SettingsSample(tab: .advanced, variables: []) },
        entry("globalList", height: 600) { SettingsSample(tab: .global, global: .init(GlobalSample.list)) },
        entry("globalEditing", height: 640) {
            SettingsSample(
                tab: .global,
                global: .init(GlobalSample.list, editing: "agents.targets", draft: "claude, codex, cursor"))
        },
        entry("globalEnforced", height: 720) { SettingsSample(tab: .global, global: .init(GlobalSample.enforced)) },
        entry("globalRefusal", height: 800) {
            SettingsSample(tab: .global, global: .init(GlobalSample.enforced, refusal: GlobalSample.refusal))
        },
    ]

    private static func entry(
        _ state: String, height: CGFloat, _ make: @escaping @MainActor @Sendable () -> SettingsSample
    ) -> Entry {
        Entry(id: "P3-13", state: state, size: CGSize(width: Size.settingsWidth, height: height)) { AnyView(make()) }
    }
}

/// Settings › Global's sample documents: the design world's config.toml (`config.global.json`), and the same with
/// `min-release-age` enforced, `allow-ranges` from `SKILLCASK_ALLOW_RANGES` and an `allow-sources` URL.
@MainActor enum GlobalSample {
    struct State {
        let document: ConfigListDocument?
        var editing: String?
        var draft = ""
        var refusal: CLISettingsStore.SettingRefusal?

        init(
            _ document: ConfigListDocument?, editing: String? = nil, draft: String = "",
            refusal: CLISettingsStore.SettingRefusal? = nil
        ) {
            self.document = document
            self.editing = editing
            self.draft = draft
            self.refusal = refusal
        }
    }

    static let list = DesignFixtures.decode(ConfigListDocument.self, "config.global")

    static let enforced: ConfigListDocument = {
        var settings = list.settings
        settings["policy.enforce"] = ConfigValueDocument(
            value: .array([.string("min-release-age")]), from: "config.toml")
        settings["policy.min-release-age"] = ConfigValueDocument(value: .string("3d"), from: "config.toml, enforced")
        settings["policy.allow-ranges"] = ConfigValueDocument(value: .bool(false), from: "environment")
        settings["policy.allow-sources"] = ConfigValueDocument(
            value: .array([.string("packagist"), .string("https://skills.acme.example/composer/")]), from: "config.toml"
        )
        return ConfigListDocument(file: list.file, settings: settings)
    }()

    /// What 0.9.4 prints for `-g config -- agents.targets claude claud` (an agent name it does not know).
    static let refusal = CLISettingsStore.SettingRefusal(
        key: "agents.targets",
        message: ErrorCopy.message(
            for: .failed(
                code: .problem,
                message: "~/.config/skillcask/config.toml: agents.targets: unknown agent \"claud\"; known: claude, "
                    + "kiro, junie, codex, copilot, cursor, gemini, opencode, amp, devin, roo, cline, goose, factory, "
                    + "vibe; a path needs a \"/\", e.g. \"./claud\"",
                hint: nil, stderr: ""),
            title: SettingsCopy.couldNotChange("agents.targets")))
}

/// One Settings pane over the fixture stores, seeded with the boards' values.
private struct SettingsSample: View {
    let tab: SettingsView.Tab
    var configured = false
    var token = ""
    var global: GlobalSample.State?
    private let stores: Boot.Stores

    /// The board's table: a cache directory and a proxy.
    static let boardVariables = DesignFixtures.settings.environment.map {
        SettingsStore.EnvironmentVariable(name: $0.name, value: $0.value)
    }

    init(
        tab: SettingsView.Tab, configured: Bool = false, skillsSh: CLISettingsStore.SkillsSh = .on,
        gitHub: CLISettingsStore.GitHub = .unknown, token: String = "", failure: UserMessage? = nil,
        tokenStorage: CLISettingsStore.TokenStorage? = nil, tokenWarnings: [String] = [],
        variables: [SettingsStore.EnvironmentVariable] = boardVariables, sheetOpen: Bool = false,
        global: GlobalSample.State? = nil
    ) {
        self.tab = tab
        self.configured = configured
        self.token = token
        self.global = global
        stores = Boot.fixtures(sheet: sheetOpen ? .addSkill(query: nil) : nil)
        stores.settings.checkUpdatesOnOpen = DesignFixtures.settings.checkOnOpen
        stores.app.cliSettings.preload(
            skillsSh: skillsSh, gitHub: gitHub, gitHubFailure: failure, tokenStorage: tokenStorage,
            tokenWarnings: tokenWarnings)
        stores.app.setEnvironmentVariables(variables)
        if let global {
            stores.app.cliSettings.preloadGlobal(global.document, refusal: global.refusal)
        }
    }

    var body: some View {
        pane
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.surfaceGrouped)
            .skillcaskEnvironment(
                app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client)
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .general:
            GeneralPane(
                toolOverride: GeneralPane.Tool(
                    path: DesignFixtures.settings.toolPath, version: DesignFixtures.settings.toolVersion,
                    configured: configured))
        case .search: SearchPane()
        case .updates: UpdatesPane(token: token)
        case .advanced: AdvancedPane(adoptedOverride: DesignFixtures.settings.adoptedSummary)
        case .global:
            GlobalPane(editing: global?.editing, draft: global?.draft ?? "")
        }
    }
}

#Preview("Settings General, light") {
    SettingsSample(tab: .general)
}

#Preview("Settings Global, light") {
    SettingsSample(tab: .global, global: .init(GlobalSample.enforced))
}

#Preview("Settings Updates, dark") {
    SettingsSample(tab: .updates, gitHub: .signedOut)
        .preferredColorScheme(.dark)
}
