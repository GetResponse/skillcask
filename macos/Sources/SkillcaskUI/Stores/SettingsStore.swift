import Foundation
import Observation
import SkillcaskCore

/// The user's settings (S14), backed by `UserDefaults` and read by the other stores. Every property writes
/// through on change, so a value survives a relaunch; the suite is injected so tests never touch the real
/// defaults. Nothing here runs the CLI: the binary path is only stored, `AppStore` validates it. The skills.sh
/// switch is not here: its one home is config.toml (`CLISettingsStore`), so the app and the CLI never disagree.
/// No token is ever stored here (or anywhere by the app): `auth set` keeps it in the Keychain.
@MainActor @Observable public final class SettingsStore {
    /// Which scope the window opens with (Settings › General, "Open at launch").
    public enum OpenAtLaunch: String, CaseIterable, Hashable, Sendable {
        case lastScope
        case personal
    }

    /// One row of Settings › Advanced's environment table, in the order the user added them. `id` is the row's
    /// identity for `Table`, never stored.
    public struct EnvironmentVariable: Identifiable, Hashable, Sendable {
        public let id: UUID
        public var name: String
        public var value: String

        public init(id: UUID = UUID(), name: String, value: String) {
            self.id = id
            self.name = name
            self.value = value
        }

        /// The policy accepts the name (`EnvironmentPolicy.allowsOverride`); an empty name is a row being typed.
        public var isAllowed: Bool {
            EnvironmentPolicy.allowsOverride(name)
        }

        /// The value holds URL credentials (`scheme://user:pass@`): applied this session, never written to disk.
        public var hasCredentials: Bool {
            EnvironmentPolicy.hasCredentials(value)
        }

        /// What goes to `UserDefaults`: the name always, the value only when `EnvironmentPolicy.mayStoreValue`
        /// allows it, so a refused name (or one on its way to being refused) or a credentialed URL never reaches
        /// disk.
        /// The row as written, with `committed` (the value at the last commit) in place of the live one.
        func stored(committed: String?) -> [String: String] {
            let value = committed ?? ""
            return ["name": name, "value": EnvironmentPolicy.mayStoreValue(name: name, value: value) ? value : ""]
        }
    }

    /// The keys, in one place so the tests and a future migration can name them.
    enum Key {
        static let binaryPath = "binaryPath"
        static let openAtLaunch = "openAtLaunch"
        static let recentProjects = "recentProjects"
        static let lastScope = "lastScope"
        static let checkUpdatesOnOpen = "checkUpdatesOnOpen"
        static let environmentVariables = "environmentVariables"
        static let addSkillSheetSize = "addSkillSheetSize"
        /// The value stored under `lastScope` for the personal scope; a project stores its path.
        static let personalScope = "personal"
    }

    private let defaults: UserDefaults

    // MARK: - State

    /// A path the user chose over the bundled or `PATH` binary; nil means auto-detect.
    public var binaryPath: String? {
        didSet { defaults.set(binaryPath, forKey: Key.binaryPath) }
    }

    /// Which scope the window opens with.
    public var openAtLaunch: OpenAtLaunch {
        didSet { defaults.set(openAtLaunch.rawValue, forKey: Key.openAtLaunch) }
    }

    /// Project roots, most recent first, as the sidebar lists them under Projects.
    public var recentProjects: [URL] {
        didSet { defaults.set(recentProjects.map(\.path), forKey: Key.recentProjects) }
    }

    /// The scope open when the app last quit; what `.lastScope` reopens.
    public var lastScope: Scope? {
        didSet { defaults.set(Self.stored(lastScope), forKey: Key.lastScope) }
    }

    /// Run `outdated` when a scope opens (off by default: it hits GitHub unauthenticated).
    public var checkUpdatesOnOpen: Bool {
        didSet { defaults.set(checkUpdatesOnOpen, forKey: Key.checkUpdatesOnOpen) }
    }

    /// Settings › Advanced's table, rows the policy refuses included (they show a warning and never apply). Written
    /// through `EnvironmentVariable.stored`: refused rows and credentialed values keep their value in memory only.
    ///
    /// Names are written live; a value only once committed (`commitEnvironmentValues`: end of editing, focus loss,
    /// submit), so a value half typed (`http://me:pa55` before its `@`) never reaches disk.
    public var environmentVariables: [EnvironmentVariable] {
        didSet {
            let ids = Set(environmentVariables.map(\.id))
            committedValues = committedValues.filter { ids.contains($0.key) }
            writeEnvironment()
        }
    }

    /// The size the user left the Add Skill sheet at, as written: `SheetSizing.ideal` clamps it to the minimum, the
    /// cap and the screen it opens on. A value that is not two finite, positive numbers reads as nil. Not observed:
    /// the sheet reads it once when it opens, so a save never re-runs a view.
    @ObservationIgnored public var addSkillSheetSize: CGSize? {
        didSet {
            defaults.set(
                addSkillSheetSize.map { [Double($0.width), Double($0.height)] }, forKey: Key.addSkillSheetSize)
        }
    }

    /// The value of each row at its last commit; rows read from disk start committed.
    @ObservationIgnored private var committedValues: [UUID: String] = [:]

    /// - Parameter defaults: The suite to read and write; tests pass their own.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binaryPath = defaults.string(forKey: Key.binaryPath)
        openAtLaunch =
            defaults.string(forKey: Key.openAtLaunch).flatMap(OpenAtLaunch.init(rawValue:)) ?? .lastScope
        recentProjects = (defaults.stringArray(forKey: Key.recentProjects) ?? []).map { URL(fileURLWithPath: $0) }
        lastScope = defaults.string(forKey: Key.lastScope).flatMap(Self.scope(stored:))
        checkUpdatesOnOpen = defaults.bool(forKey: Key.checkUpdatesOnOpen)
        environmentVariables = ((defaults.array(forKey: Key.environmentVariables) as? [[String: String]]) ?? [])
            .compactMap { row in
                row["name"].map { EnvironmentVariable(name: $0, value: row["value"] ?? "") }
            }
        committedValues = Dictionary(uniqueKeysWithValues: environmentVariables.map { ($0.id, $0.value) })
        addSkillSheetSize = Self.size(stored: defaults.object(forKey: Key.addSkillSheetSize))
    }

    /// Takes every row's current value as committed and writes the table (values only where
    /// `EnvironmentPolicy.mayStoreValue` allows). Settings › Advanced calls it when a cell ends editing.
    public func commitEnvironmentValues() {
        committedValues = Dictionary(uniqueKeysWithValues: environmentVariables.map { ($0.id, $0.value) })
        writeEnvironment()
    }

    private func writeEnvironment() {
        let rows = environmentVariables.map { $0.stored(committed: committedValues[$0.id]) }
        defaults.set(rows, forKey: Key.environmentVariables)
    }

    // MARK: - Derived

    /// The rows the policy accepts, as `EnvironmentPolicy.overrides`; for a name typed twice, the later row wins.
    public var environmentOverrides: [String: String] {
        environmentVariables.filter(\.isAllowed).reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    // MARK: - Actions

    /// Puts `root` first in the recents, once.
    public func remember(project root: URL) {
        let standardized = root.standardizedFileURL
        recentProjects = [standardized] + recentProjects.filter { $0 != standardized }
    }

    /// Drops `root` from the recents ("Remove from Sidebar").
    public func forget(project root: URL) {
        let standardized = root.standardizedFileURL
        recentProjects.removeAll { $0 == standardized }
    }

    // MARK: - Storage

    static func stored(_ scope: Scope?) -> String? {
        switch scope {
        case nil: nil
        case .personal: Key.personalScope
        case .project(let url): url.path
        }
    }

    static func scope(stored text: String) -> Scope? {
        text == Key.personalScope ? .personal : .project(at: text)
    }

    /// `[width, height]` as written by `addSkillSheetSize`; nil for anything else (a hand-edited plist, a wrong type).
    static func size(stored value: Any?) -> CGSize? {
        guard let numbers = value as? [Double], numbers.count == 2 else { return nil }
        let size = CGSize(width: numbers[0], height: numbers[1])
        return SheetSizing.isUsable(size) ? size : nil
    }
}
