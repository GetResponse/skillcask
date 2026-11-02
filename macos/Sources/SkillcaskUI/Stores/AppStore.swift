import Foundation
import Observation
import SkillcaskCore
import SkillcaskDomain

/// The window's root state: whether the CLI is usable, the scopes in the sidebar, which one is selected,
/// and one `ScopeStore` per visited scope. Lives as long as the app; never recreated on a scope switch, so
/// switching back is instant and the previous snapshot shows while it refreshes.
@MainActor @Observable public final class AppStore {
    /// Where the app stands with the binary (S13): a sheet covers everything until `.ready`.
    public enum CLIState: Hashable, Sendable {
        case locating
        case missing(searched: [String])
        case tooOld(found: Version, needs: Version)
        case ready(Capabilities)
    }

    /// One sidebar row: the scope, its name and the path shown under it (nil for the personal row, which the
    /// board draws on one line).
    public struct ScopeItem: Identifiable, Hashable, Sendable {
        public let scope: Scope
        /// "My Skills", or the project's folder name.
        public let name: String
        /// The project's `~`-abbreviated path; nil for the personal row (one line on the board).
        public let subtitle: String?
        /// A project folder has a skills.toml (else `.noManifest`, the Set Up block); always true for the
        /// personal scope here (its `init -g` state is only known from `status -g`).
        public let isSetUp: Bool

        public var id: Scope { scope }

        public init(scope: Scope, name: String, subtitle: String?, isSetUp: Bool = true) {
            self.scope = scope
            self.name = name
            self.subtitle = subtitle
            self.isSetUp = isSetUp
        }
    }

    /// What the toolbar, menus, rows and detail ask the window to present over the selected scope, through
    /// `request(_:)`. `MainWindow` shows every case but `.remove` as a sheet through `SheetHost` (`presentedSheet`);
    /// `.remove` is the system alert of S10 (`removal`). Each case carries what its destination needs to open:
    /// Review Update (S7), Add Skill (S8), Adopt and Remove (S9, S10), Find Projects (Flow-F1
    /// step 4).
    public enum Sheet: Identifiable, Hashable, Sendable {
        /// Review one package's update. `target` is the version the row or strip offered; nil lets `diff` choose
        /// the newest inside the range. `reviewOnly` is set when the tag moved (Q3): the sheet then never makes
        /// Update its default button.
        case update(package: String, target: String?, reviewOnly: Bool)
        /// Review every package with an update inside its range.
        case updateAll
        /// Search and add; `query` pre-fills the field ("Find “…” in sources").
        case addSkill(query: String?)
        /// Adopt not-managed skills: one from a row or the detail, several from the Not managed filter.
        case adopt(skills: [String])
        /// Remove skills: a system alert, not a sheet.
        case remove(skills: [String])
        /// Find Projects in Folder…: `projects` under `root`, then the checklist of the folders it found. App-level:
        /// the scope it is pinned to is only where the window was.
        case findProjects(root: URL)

        public var id: String {
            switch self {
            case .update(let package, let target, _): "update-\(package)-\(target ?? "")"
            case .updateAll: "update-all"
            case .addSkill(let query): "add-\(query ?? "")"
            case .adopt(let skills): "adopt-\(skills.joined(separator: ","))"
            case .remove(let skills): "remove-\(skills.joined(separator: ","))"
            case .findProjects(let root): "find-projects-\(root.path)"
            }
        }

        /// Presented as an alert rather than a sheet.
        public var isAlert: Bool {
            if case .remove = self { true } else { false }
        }

        /// Update… for `entry`: its package (the skill id for a package-less row), the version it offers, and
        /// review-only when its tag moved (`DetailActions.isTagMoved`).
        public static func update(for entry: SkillEntry) -> Sheet {
            .update(
                package: entry.package ?? entry.id, target: DetailActions.updateTarget(of: entry),
                reviewOnly: DetailActions.isTagMoved(entry))
        }

        /// Review one package from a place that knows no entry (Overview's Updates card): `diff` chooses.
        public static func update(package: String) -> Sheet {
            .update(package: package, target: nil, reviewOnly: false)
        }
    }

    /// A request on screen: the sheet or alert, the scope it was asked for (pinned, so switching the sidebar or
    /// Open Recent never rebinds it), and an identity so a close clears only its own presentation.
    public struct Presentation: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let sheet: Sheet
        public let scope: Scope
    }

    /// The settings the sidebar (recents) and the boot (binary path, open-at-launch) read.
    public let settings: SettingsStore
    /// The environment every child gets: the live client reads it at every spawn (through `environmentSource`),
    /// and `manifest(of:)` and `configFile()` resolve through it, so a Settings override reaches all three from the
    /// next run on. Starts from the policy given plus Settings › Advanced's table; `setEnvironmentVariables(_:)`
    /// changes it.
    public private(set) var environment: EnvironmentPolicy {
        didSet { environmentSource.policy = environment }
    }
    /// The live policy `ProcessRunner` reads; shared by reference so no client needs rebuilding.
    @ObservationIgnored private let environmentSource: EnvironmentSource
    /// The policy the app was built with, before Settings' table: a table edit rebuilds `environment` from it, so
    /// removing a row restores a base override of the same name rather than wiping it.
    @ObservationIgnored private let baseEnvironment: EnvironmentPolicy
    /// Settings' CLI-side state (S14: skills.sh in config.toml, the GitHub token); app-lifetime, so this session's
    /// sign-in survives closing the Settings window.
    public let cliSettings = CLISettingsStore()
    /// The one mutation queue of the app, shared with `ActionRunner`.
    public let queue: MutationQueue
    /// Watches the selected scope's files and refreshes it when something outside the app changes them.
    @ObservationIgnored public let liveRefresh: LiveRefresh
    private let locator: Locator
    private let makeClient: @Sendable (URL) -> any CLIClient
    private let textReader: ScopeStore.TextReader
    private let manifestExists: @Sendable (URL) -> Bool

    /// Whether `root/skills.toml` exists on disk: the live check.
    public static let manifestOnDisk: @Sendable (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.appending(path: "skills.toml").path)
    }

    // MARK: - State

    public private(set) var cli: CLIState = .locating
    /// Why the last boot failed, for the onboarding sheet's Details (S13).
    public private(set) var bootError: CLIError?
    /// Project roots without a skills.toml, from the last manifest check (`refreshSetUp`).
    public private(set) var notSetUp: Set<URL> = []
    public var selectedScope: Scope? {
        didSet { settings.lastScope = selectedScope }
    }
    /// The sheet or alert on screen; see `request(_:)` and `dismiss(_:)`.
    public private(set) var presentation: Presentation?
    /// A detection failed and none has succeeded since: the S13 onboarding sheet stays up, also while Try Again
    /// or Locate… re-detects (`cli` is `.locating` then), until the CLI is ready.
    public private(set) var detectionFailed = false
    /// Try Again or Locate… is running: a second press while one runs is ignored, so a double click detects once.
    /// Set on the main actor before the first `await`, so two presses can never both pass the check.
    public private(set) var isRedetecting = false

    /// The S13 onboarding sheet covers the window: the CLI is missing or too old, or being re-detected
    /// after such a failure.
    public var isOnboarding: Bool {
        detectionFailed && !isReady
    }

    /// The app-update sheet or its alert is up (`AppUpdateStore.isPresenting`, mirrored by `MainWindow`): it has a
    /// presenter of its own, so this keeps a scope sheet from stacking on it.
    public var isAppUpdatePresenting = false

    /// A sheet, the Remove alert, the onboarding sheet or the app-update sheet is up: every other request is
    /// refused and the commands that make one are disabled.
    public var isPresenting: Bool {
        presentation != nil || isOnboarding || isAppUpdatePresenting
    }

    /// The presentation when it is a sheet, for `.sheet(item:)`.
    public var presentedSheet: Presentation? {
        presentation.flatMap { $0.sheet.isAlert ? nil : $0 }
    }

    /// The presentation when it is the Remove alert.
    public var removal: Presentation? {
        presentation.flatMap { $0.sheet.isAlert ? $0 : nil }
    }

    /// The one entry point for a sheet or the alert, over the selected scope. Refused (false) while another is up,
    /// so a menu shortcut can never replace a running sheet or pop the alert over it, and without a scope or its
    /// store (the CLI not ready).
    @discardableResult public func request(_ sheet: Sheet) -> Bool {
        guard !isPresenting, let scope = selectedScope, store(for: scope) != nil else { return false }
        presentation = Presentation(id: UUID(), sheet: sheet, scope: scope)
        return true
    }

    /// Closes the sheet or alert whose pinned scope has no store any more (the CLI went away, or the scope left
    /// the sidebar), so `isPresenting` cannot stick behind an empty sheet or an alert that never shows.
    /// `MainWindow` calls it whenever the presentation, the CLI state or the sidebar's projects change.
    /// Asks `hasStore(for:)`, not `store(for:)`: the check must not build (or bring back) a store as a side effect.
    public func dropOrphanedPresentation() {
        if let orphan = Self.orphan(presentation, hasStore: { hasStore(for: $0) }) {
            dismiss(orphan)
        }
    }

    /// `presentation` when its scope has no store; nil otherwise.
    nonisolated static func orphan(_ presentation: Presentation?, hasStore: (Scope) -> Bool) -> Presentation? {
        presentation.flatMap { hasStore($0.scope) ? nil : $0 }
    }

    /// Closes `presentation` if it is still the one on screen; a stale close (a late `onSuccess`) does nothing.
    public func dismiss(_ presentation: Presentation) {
        if self.presentation?.id == presentation.id {
            self.presentation = nil
        }
    }
    /// Where the located binary is, for Settings › General.
    public private(set) var binary: Locator.Choice?
    @ObservationIgnored private var client: (any CLIClient)?
    /// Internal, not private, so tests can leave stale stores behind a CLI that is not ready.
    @ObservationIgnored var stores: [Scope: ScopeStore] = [:]
    /// The badges of the projects not opened yet: one background `status` each (Flow-F5).
    public let summaries = ScopeSummaries()
    /// Where every scope store records the reads the user starts (S15): `ActionRunner.record(_:)`, set by `Boot`.
    @ObservationIgnored public var recordActivity: ActionRunner.ActivitySink?

    /// The live app: locates the binary on `boot()` and talks to it through `makeClient`.
    public init(
        settings: SettingsStore, queue: MutationQueue = MutationQueue(), locator: Locator = Locator(),
        environment: EnvironmentPolicy = .default, makeClient: (@Sendable (URL) -> any CLIClient)? = nil,
        textReader: @escaping ScopeStore.TextReader = ScopeStore.readText,
        manifestExists: @escaping @Sendable (URL) -> Bool = AppStore.manifestOnDisk,
        liveRefresh: LiveRefresh = LiveRefresh(watcher: FSEventsWatcher())
    ) {
        self.settings = settings
        self.queue = queue
        self.liveRefresh = liveRefresh
        self.locator = locator
        let policy = Self.policy(environment, with: settings)
        let source = EnvironmentSource(policy)
        self.environment = policy
        environmentSource = source
        baseEnvironment = environment
        // The live client refuses commands a folder without skills.toml would send to a parent project, and times
        // out reads (`GuardedClient`); an injected `makeClient` (tests) is used as given.
        self.makeClient =
            makeClient ?? {
                GuardedClient(ProcessRunner(executable: $0, source: source), manifestExists: manifestExists)
            }
        self.textReader = textReader
        self.manifestExists = manifestExists
        liveRefresh.app = self
    }

    /// A ready app over a known client: tests and the fixture boot skip the location and the version gate.
    public init(
        settings: SettingsStore, queue: MutationQueue = MutationQueue(), client: any CLIClient,
        capabilities: Capabilities, environment: EnvironmentPolicy = .default,
        textReader: @escaping ScopeStore.TextReader = ScopeStore.readText,
        manifestExists: @escaping @Sendable (URL) -> Bool = AppStore.manifestOnDisk,
        liveRefresh: LiveRefresh = LiveRefresh(watcher: NoFileWatcher())
    ) {
        self.settings = settings
        self.queue = queue
        self.liveRefresh = liveRefresh
        let policy = Self.policy(environment, with: settings)
        self.environment = policy
        environmentSource = EnvironmentSource(policy)
        baseEnvironment = environment
        locator = Locator()
        makeClient = { _ in client }
        self.textReader = textReader
        self.manifestExists = manifestExists
        self.client = client
        cli = .ready(capabilities)
        liveRefresh.app = self
    }

    // MARK: - Derived

    /// Personal first, then the recent projects in order (Settings).
    public var scopes: [ScopeItem] {
        [ScopeItem(scope: .personal, name: ShellCopy.personalScope, subtitle: nil)]
            + settings.recentProjects.map {
                ScopeItem(
                    scope: .project($0), name: Self.name(of: $0), subtitle: Self.subtitle(of: $0),
                    isSetUp: !notSetUp.contains($0.standardizedFileURL))
            }
    }

    /// The project rows alone, in sidebar order.
    public var projects: [ScopeItem] {
        scopes.filter { !$0.scope.isPersonal }
    }

    /// The CLI was located and passed the version gate.
    public var isReady: Bool {
        if case .ready = cli { true } else { false }
    }

    /// The located CLI's capabilities; nil until ready.
    public var capabilities: Capabilities? {
        if case .ready(let capabilities) = cli { capabilities } else { nil }
    }

    /// The selected scope's store, once the CLI is ready.
    public var selectedStore: ScopeStore? {
        selectedScope.flatMap { store(for: $0) }
    }

    /// The store of `scope`, created on first use and kept: nil until the CLI is ready.
    public func store(for scope: Scope) -> ScopeStore? {
        guard let client, let capabilities else { return nil }
        if let store = stores[scope] {
            return store
        }
        let store = ScopeStore(
            scope: scope, client: client, capabilities: capabilities, settings: settings, queue: queue,
            textReader: textReader)
        store.recordActivity = recordActivity
        store.onManifestMissing = { [weak self] in
            Task { await self?.refreshSetUp() }
        }
        stores[scope] = store
        return store
    }

    /// Whether `scope` has, or may get, a store that belongs on screen, without building one: the CLI is ready
    /// (`store(for:)`'s guard comes first, so a store left from an old client does not count) and the scope is
    /// still in the sidebar (My Skills always is). A project removed from the sidebar has none, even though
    /// `store(for:)` would build it again.
    func hasStore(for scope: Scope) -> Bool {
        client != nil && capabilities != nil && isListed(scope)
    }

    /// My Skills, or a project in the sidebar.
    func isListed(_ scope: Scope) -> Bool {
        scope.isPersonal || scopes.contains { $0.scope == scope }
    }

    /// Whether `scope` has a skills.toml as the last manifest check saw it (`ScopeItem.isSetUp`); a scope not in
    /// the sidebar counts as set up (nothing in the window acts on it). The toolbar and the Skill and Scope menus
    /// act only on a set-up scope.
    public func isSetUp(_ scope: Scope) -> Bool {
        item(for: scope)?.isSetUp ?? true
    }

    /// The store of `scope` only when the scope was visited.
    public func visitedStore(for scope: Scope) -> ScopeStore? {
        stores[scope]
    }

    /// The sidebar badge of `scope`: its store's snapshot once visited, else its background `status` summary
    /// (red and amber rows only: `outdated` runs on an explicit Check); nil draws no badge.
    public func attention(for scope: Scope) -> Attention? {
        stores[scope]?.snapshot?.attention ?? summaries.attention[scope]
    }

    // MARK: - Settings

    /// `environment` with Settings' table on top of its overrides.
    private static func policy(_ environment: EnvironmentPolicy, with settings: SettingsStore) -> EnvironmentPolicy {
        var policy = environment
        policy.overrides.merge(settings.environmentOverrides) { _, table in table }
        return policy
    }

    /// Settings › Advanced: stores the table and applies the rows the policy allows to every run that starts
    /// after this call (running ones keep the environment they started with).
    public func setEnvironmentVariables(_ rows: [SettingsStore.EnvironmentVariable]) {
        settings.environmentVariables = rows
        environment = Self.policy(baseEnvironment, with: settings)
    }

    /// The CLI's config.toml, resolved in the children's environment (Settings › Advanced, Open config.toml).
    public func configFile(base: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        CLIConfig.file(
            environment: environment.environment(from: base), home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// What the app-update check runs with (`AppUpdateStore.Context`): the ready client, where the binary was found
    /// (the bundled helper passes `SelfCheckGate` whatever it reports) and its capabilities; nil until ready.
    public var updateContext: AppUpdateStore.Context? {
        guard let client, let capabilities else { return nil }
        return AppUpdateStore.Context(client: client, binary: binary, capabilities: capabilities)
    }

    /// What Settings' own commands (skills.sh, `auth`) run with; nil until the CLI is ready.
    public var cliContext: CLISettingsStore.Context? {
        guard let client, let capabilities else { return nil }
        return CLISettingsStore.Context(client: client, capabilities: capabilities)
    }

    /// Settings › General, "Use the detected one": forgets the chosen binary and detects again (bundled, then
    /// `PATH`). The scope stores built over the old client are dropped so every later run uses the new one.
    /// Refused while a sheet or the Remove alert is up (`canChangeBinary`): it holds a store this would drop.
    public func useDetectedBinary() async {
        guard !isRedetecting, canChangeBinary else { return }
        isRedetecting = true
        defer { isRedetecting = false }
        settings.binaryPath = nil
        client = nil
        stores.removeAll()
        summaries.reset()
        cli = .locating
        await boot()
    }

    /// The CLI's config directory (config.toml, the personal manifest), resolved in the children's environment.
    public func configDirectory(base: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        Scope.configDirectory(
            environment: environment.environment(from: base), home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// The skills.toml the CLI reads for `scope`, resolved in the children's environment (`environment`).
    public func manifest(of scope: Scope, base: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        scope.manifest(environment: environment.environment(from: base))
    }

    /// The sidebar row of `scope`; nil when the scope is not listed.
    public func item(for scope: Scope) -> ScopeItem? {
        scopes.first { $0.scope == scope }
    }

    // MARK: - Boot

    /// Try Again (S13): detects again unless Try Again or Locate… is already running.
    public func tryAgain() async {
        guard !isRedetecting else { return }
        isRedetecting = true
        defer { isRedetecting = false }
        await boot()
    }

    /// Locate → `--version` → `Capabilities`, then the scope Settings asks for. Runs again after "Try again" or a
    /// binary path change; a ready app only re-selects.
    public func boot() async {
        if !isReady {
            await locate()
        }
        guard isReady else { return }
        await refreshSetUp()
        if selectedScope == nil {
            selectedScope = initialScope
        }
        summarizeProjects()
    }

    private func locate() async {
        cli = .locating
        bootError = nil
        switch await find(configured: settings.binaryPath) {
        case .failure(let error):
            fail(error, searched: [])
            return
        case .success(let choice):
            binary = choice
            do {
                let (client, capabilities) = try await probe(choice.url)
                self.client = client
                cli = .ready(capabilities)
                detectionFailed = false
            } catch {
                fail(error, searched: [choice.url.path])
            }
        }
    }

    /// Locate… (S13) and Settings' Choose…: `url` goes through the same locator and `--version` gate as a boot.
    /// Only a binary that passes is written to Settings (`binaryPath`) and boots the app, and the scope stores are
    /// rebuilt over it; a refused one leaves Settings and `cli` as they were. Returns why it was refused, nil when the app is ready, `.cancelled` when a detection was already
    /// running. `url` is stored as given (the symlink the user picked, not the file it resolves to), so a Homebrew
    /// upgrade that moves the Cellar target keeps working.
    /// Refused (`.cancelled`, nothing changes) while a sheet or the Remove alert is up: dropping the stores would
    /// pull the store out from under it (Settings is a window of its own, so it stays usable meanwhile).
    @discardableResult public func locate(executable url: URL) async -> CLIError? {
        guard !isRedetecting, canChangeBinary else { return .cancelled }
        isRedetecting = true
        defer { isRedetecting = false }
        let path = url.path
        switch await find(configured: path) {
        case .failure(let error):
            return error
        case .success(let choice):
            do {
                let (client, capabilities) = try await probe(choice.url)
                settings.binaryPath = path
                binary = choice
                self.client = client
                // Built over the old client: dropped so every open scope's next command runs the chosen tool.
                stores.removeAll()
                summaries.reset()
                bootError = nil
                cli = .ready(capabilities)
                detectionFailed = false
            } catch {
                return error
            }
        }
        await boot()
        return nil
    }

    /// Choose… and "Use the detected one" may rebuild the stores: not while a presentation holds one.
    public var canChangeBinary: Bool {
        presentation == nil
    }

    /// `Locator.locate` off the main actor: the file checks never block the window.
    private func find(configured: String?) async -> Result<Locator.Choice, CLIError> {
        let locator = locator
        let located: Result<Locator.Choice, CLIError> =
            await Task.detached {
                do {
                    return .success(try locator.locate(configured: configured))
                } catch let error as CLIError {
                    return .failure(error)
                } catch {
                    return .failure(.launchFailed(String(describing: error)))
                }
            }
            .value
        return located
    }

    /// `--version` through the gate on a client for `url`.
    private func probe(_ url: URL) async throws(CLIError) -> (any CLIClient, Capabilities) {
        let client = makeClient(url)
        let probe = try Invocation(.version, in: .personal, capabilities: Capabilities(version: Capabilities.minimum))
        return (client, try await client.capabilities(via: probe))
    }

    private func fail(_ error: CLIError, searched: [String]) {
        bootError = error
        detectionFailed = true
        switch error {
        case .binaryMissing(let paths): cli = .missing(searched: paths)
        case .binaryIsApp(let path): cli = .missing(searched: [path])
        case .tooOld(let found, let needs): cli = .tooOld(found: found, needs: needs)
        default: cli = .missing(searched: searched)
        }
    }

    private var initialScope: Scope {
        switch settings.openAtLaunch {
        case .personal:
            return .personal
        case .lastScope:
            if let last = settings.lastScope, scopes.contains(where: { $0.scope == last }) {
                return last
            }
            return .personal
        }
    }

    // MARK: - Scopes

    /// Adds `folder` to the sidebar (first in the recents) and opens it.
    public func open(folder: URL) {
        open(folders: [folder])
    }

    /// Adds `folders` to the sidebar in their order, ahead of the other recents, and selects the first: Open
    /// Folder…, a drop on the sidebar and Find Projects' Add all come here. A folder without skills.toml shows the
    /// Set Up block once the manifest check returned. Returns that check (and the badges after it), for tests; nil
    /// (nothing added) for no folder or while the CLI is not ready, when every way in is disabled.
    @discardableResult public func open(folders: [URL]) -> Task<Void, Never>? {
        guard isReady, let first = folders.first else { return nil }
        for folder in folders.reversed() {
            settings.remember(project: folder)
        }
        selectedScope = .project(first.standardizedFileURL)
        return Task {
            await refreshSetUp()
            summarizeProjects()
        }
    }

    /// A drop on the sidebar: the directories among `urls` open as Open Folder… would (`open(folders:)`), the first
    /// selected; files, symlinks and anything not on disk are ignored. Nil (the drop is refused) when none is a
    /// directory or the CLI is not ready.
    @discardableResult public func open(
        dropped urls: [URL], isDirectory: (URL) -> Bool = AppStore.isDirectory
    ) -> Task<Void, Never>? {
        open(folders: urls.filter { $0.isFileURL && isDirectory($0) })
    }

    /// Whether `url` is a real directory on disk. A symlink to one is not (`isDirectoryKey` does not follow the last
    /// component), as the CLI refuses a symlinked project directory.
    public nonisolated static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Which recent projects have a skills.toml, through `manifestExists` off the main actor, so the
    /// sidebar can draw the not-set-up rows and the detail the Set Up block. Runs on boot, after Open Folder…
    /// and after Find Projects; the fixture boot injects a check that never touches the disk.
    public func refreshSetUp() async {
        let roots = settings.recentProjects.map(\.standardizedFileURL)
        let exists = manifestExists
        let missing = await Task.detached { Set(roots.filter { !exists($0) }) }.value
        notSetUp = missing
    }

    /// Previews: the manifest check's answer at once, without the hop off the main actor (fixture checks only).
    func preloadSetUp() {
        notSetUp = Set(settings.recentProjects.map(\.standardizedFileURL).filter { !manifestExists($0) })
    }

    /// Set Up (Overview-States "Folder without skills.toml"): `init` through the runner, whose refresh fills the
    /// store, then the manifest check again, so the row drops "Not set up" and the list shows "No skills yet"
    /// without a restart (Flow-F1 "Empty after Set Up"). The check runs whatever `init` said: the disk decides.
    public func setUp(_ store: ScopeStore, runner: ActionRunner) async {
        await runner.setUp(in: store)
        await refreshSetUp()
    }

    /// Drops a project from the sidebar and forgets its store and badge; the personal row cannot be removed, and
    /// neither can a project a sheet or the Remove alert is pinned to (Settings › General's Clear Recent can be
    /// pressed while the main window shows one). Returns whether it was removed.
    @discardableResult public func removeFromSidebar(_ scope: Scope) -> Bool {
        guard case .project(let url) = scope, canRemoveFromSidebar(scope) else { return false }
        settings.forget(project: url)
        stores.removeValue(forKey: scope)
        summaries.forget(scope)
        if selectedScope == scope {
            selectedScope = .personal
        }
        return true
    }

    /// No presentation is pinned to `scope`.
    public func canRemoveFromSidebar(_ scope: Scope) -> Bool {
        presentation?.scope != scope
    }

    /// `projects --json -- <root>`: the folders under `root` with a skills.toml, for the Find Projects sheet.
    public func projects(under root: URL) async -> Result<[URL], CLIError> {
        guard let client, let capabilities else { return .failure(.cancelled) }
        do {
            let invocation = try Invocation(.projects(roots: [root]), in: .project(root), capabilities: capabilities)
            let document = try await client.document(ProjectsDocument.self, for: invocation)
            return .success(
                document.projects.map {
                    URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath).standardizedFileURL
                })
        } catch {
            return .failure(error)
        }
    }

    /// Starts the badge reads of My Skills and the set-up projects that have no store yet (the selected one gets
    /// its store).
    private func summarizeProjects() {
        guard let client, let capabilities else { return }
        let unopened = scopes.filter { $0.isSetUp && stores[$0.scope] == nil && $0.scope != selectedScope }
            .map(\.scope)
        summaries.summarize(unopened, client: client, capabilities: capabilities)
    }

    // MARK: - Names

    /// The sidebar name of a project: its folder name.
    public nonisolated static func name(of root: URL) -> String {
        root.lastPathComponent
    }

    /// The path under a project's name, with the home directory as `~`.
    public nonisolated static func subtitle(of root: URL) -> String {
        (root.path as NSString).abbreviatingWithTildeInPath
    }
}
