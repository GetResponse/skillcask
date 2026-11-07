import Foundation
import Observation
import SkillcaskCore
import SkillcaskDomain

/// The settings that live in the CLI, not in the app (S14): `[search] skills-sh` and the other keys of config.toml
/// (Settings › Global, `-g config`), the GitHub token in git's credential helper (the Keychain on macOS), and
/// the size of the adopted copies' folder. App-lifetime
/// (`AppStore.cliSettings`), so what this session learnt survives closing the Settings window.
///
/// skills.sh goes through `skillcask -g config` (D48): read as `{"value", "from"}`, written as `config --
/// search.skills-sh true|false`, nothing else run. The app never reads or writes config.toml itself.
///
/// The token rules: it reaches the CLI only as the stdin of `auth set` (never argv, never the environment); the
/// app never writes it anywhere, never reads it back, never shows it, and keeps no reference once the run is over.
/// No command reports whether a token is stored without returning it (`credential::fill` prints the password), so
/// `gitHub` starts `.unknown` and only this session's own Save or Sign Out changes it.
@MainActor @Observable public final class CLISettingsStore {
    /// What a command needs: the ready client and its capabilities. Built by `AppStore.cliContext`.
    public struct Context: Sendable {
        public let client: any CLIClient
        public let capabilities: Capabilities

        public init(client: any CLIClient, capabilities: Capabilities) {
            self.client = client
            self.capabilities = capabilities
        }
    }

    /// `[search] skills-sh` as `-g config` reports it.
    public enum SkillsSh: Hashable, Sendable {
        /// Not read yet, or the read failed (a broken config.toml).
        case unknown
        /// Nothing sets it: Add Skill… asks (S8 consent).
        case notSet
        case on
        case off
    }

    /// What the app knows of the GitHub token.
    public enum GitHub: Hashable, Sendable {
        /// Nothing: no command tells without returning the token.
        case unknown
        /// This session's `auth set` succeeded.
        case signedIn
        /// This session's `auth remove` succeeded.
        case signedOut
    }

    /// Where `auth set` said it stored the token: the helper list it prints (`stored a N-character token for <host>
    /// with git's credential helper (<helpers>)`) names osxkeychain, or it does not.
    public enum TokenStorage: Hashable, Sendable {
        case keychain
        case otherHelper
    }

    /// The host the CLI keys GitHub API tokens by (`github::API`), and the username that makes it a Bearer token.
    public static let gitHubHost = "api.github.com"
    public static let gitHubUsername = "oauth2"
    /// The key `config` names the switch by (D48).
    public nonisolated static let skillsShKey = "search.skills-sh"

    /// Sums a folder off the main actor: `4 folders · 1.2 MB`, nil when it does not exist.
    public typealias Measurer = @Sendable (URL) async -> String?

    private let measure: Measurer

    // MARK: - State

    public private(set) var skillsSh: SkillsSh = .unknown
    /// The layer that sets it: `config.toml` or `system config.toml` (D60).
    public private(set) var skillsShFrom: String?
    /// The value being written while `config` runs.
    public private(set) var pendingSkillsSh: Bool?
    public private(set) var skillsShFailure: UserMessage?
    public private(set) var gitHub: GitHub = .unknown
    /// `auth set` or `auth remove` is running.
    public private(set) var isChangingToken = false
    public private(set) var gitHubFailure: UserMessage?
    /// Where this session's Save stored the token; nil before one.
    public private(set) var tokenStorage: TokenStorage?
    /// The CLI's warnings from that Save (the plain-text `store` helper), masked.
    public private(set) var tokenWarnings: [String] = []
    /// The last measured adopted folder and its summary (`measureAdopted(at:)`).
    public private(set) var adopted: (folder: URL, summary: String?)?

    /// `-g config --json`: every key of config.toml with its value and layer; nil before the first read and after
    /// a read that failed.
    public private(set) var globalSettings: ConfigListDocument?
    /// Why the last read of `globalSettings` failed (a broken config.toml), masked.
    public private(set) var globalSettingsFailure: UserMessage?
    /// The key whose change is running; one at a time.
    public private(set) var changingSetting: String?
    /// The CLI's refusal of the last change, under the key it was for.
    public private(set) var settingRefusal: SettingRefusal?

    /// A change the CLI refused, kept with its key; values that may hold credentials are masked in it.
    public struct SettingRefusal: Hashable, Sendable {
        public let key: String
        public let message: UserMessage
    }

    /// Set by `preload`: a preview's state is not replaced by the file on disk.
    @ObservationIgnored private var isPreloaded = false
    /// Set by `preloadGlobal`.
    @ObservationIgnored private var isGlobalPreloaded = false
    /// Counts reads of `globalSettings`: only the newest one may set it, so a slow earlier read cannot overwrite
    /// what a later one (after a change) read.
    @ObservationIgnored private var globalGeneration = 0
    /// The same for `skillsSh`.
    @ObservationIgnored private var skillsShGeneration = 0

    /// A write of config.toml is running: the skills.sh switch or a Global change. One at a time, so two `config`
    /// runs never race on the file and each read-back sees its own write.
    public var isWritingConfig: Bool {
        pendingSkillsSh != nil || changingSetting != nil
    }

    public init(measure: @escaping Measurer = CLISettingsStore.measureFolder) {
        self.measure = measure
    }

    // MARK: - skills.sh

    /// Seeds the state a preview draws; later loads keep it.
    func preload(
        skillsSh: SkillsSh, gitHub: GitHub = .unknown, gitHubFailure: UserMessage? = nil,
        tokenStorage: TokenStorage? = nil, tokenWarnings: [String] = []
    ) {
        isPreloaded = true
        self.skillsSh = skillsSh
        self.gitHub = gitHub
        self.gitHubFailure = gitHubFailure
        self.tokenStorage = tokenStorage
        self.tokenWarnings = tokenWarnings
    }

    /// Reads the switch through `-g config --json -- search.skills-sh`. A read that fails (a broken config.toml)
    /// leaves it `.unknown`: the app does not read the file itself. As for `loadGlobalSettings`, a cancelled read
    /// changes nothing and only the newest read sets the state.
    public func loadSkillsSh(in context: Context) async {
        guard !isPreloaded else { return }
        skillsShGeneration += 1
        let generation = skillsShGeneration
        do throws(CLIError) {
            let invocation = try Invocation(
                .config(key: Self.skillsShKey), in: .personal, capabilities: context.capabilities)
            // Exit 1 with `{"value": null}` when nothing sets it: the document decides, not the exit.
            let document = try await context.client.run(invocation).document(ConfigValueDocument.self)
            guard generation == skillsShGeneration else { return }
            skillsSh = Self.state(of: document) ?? .unknown
            skillsShFrom = document.from
        } catch {
            guard generation == skillsShGeneration, error != .cancelled else { return }
            skillsSh = .unknown
        }
    }

    static func state(of document: ConfigValueDocument) -> SkillsSh? {
        switch document.value {
        case .bool(true): .on
        case .bool(false): .off
        case .null: .notSet
        default: nil
        }
    }

    /// Writes the switch with `-g config -- search.skills-sh true|false` (nothing else runs), then reads it again:
    /// what the CLI reads back decides.
    public func setSkillsSh(_ on: Bool, in context: Context) async {
        guard !isWritingConfig else { return }
        pendingSkillsSh = on
        skillsShFailure = nil
        defer { pendingSkillsSh = nil }
        var failure: CLIError?
        do throws(CLIError) {
            let command = Invocation.Command.configSet(key: Self.skillsShKey, values: [on ? "true" : "false"])
            failure = try await context.client
                .run(
                    Invocation(command, in: .personal, capabilities: context.capabilities)
                )
                .failure()
        } catch {
            failure = error
        }
        await loadSkillsSh(in: context)
        // Settings › Global lists the same key.
        await loadGlobalSettings(in: context)
        if skillsSh != (on ? .on : .off) {
            skillsShFailure = ErrorCopy.message(
                for: failure ?? .launchFailed(SettingsCopy.skillsShNotSaved), title: SettingsCopy.couldNotSaveSkillsSh)
            skillsShFailure?.details = nil
        }
    }

    // MARK: - Global settings

    /// Seeds Settings › Global for a preview; later loads keep it.
    func preloadGlobal(
        _ document: ConfigListDocument?, failure: UserMessage? = nil, refusal: SettingRefusal? = nil,
        changing: String? = nil
    ) {
        isGlobalPreloaded = true
        globalSettings = document
        globalSettingsFailure = failure
        settingRefusal = refusal
        changingSetting = changing
    }

    /// Reads every key through `-g config --json`. A cancelled read (the pane went away) changes nothing, and only
    /// the newest read sets the state.
    public func loadGlobalSettings(in context: Context) async {
        guard !isGlobalPreloaded else { return }
        globalGeneration += 1
        let generation = globalGeneration
        do throws(CLIError) {
            let invocation = try Invocation(.configList, in: .personal, capabilities: context.capabilities)
            let document = try await context.client.run(invocation).document(ConfigListDocument.self)
            guard generation == globalGeneration else { return }
            globalSettings = document
            globalSettingsFailure = nil
        } catch {
            guard generation == globalGeneration, error != .cancelled else { return }
            globalSettings = nil
            var message = ErrorCopy.message(for: error, title: SettingsCopy.couldNotReadGlobal)
            message.details = nil
            globalSettingsFailure = message
        }
    }

    /// `-g config -- <key> <values…>`, then the list again. Returns whether the CLI took it; a refusal is kept in
    /// `settingRefusal` with the values of a credential-bearing key masked.
    @discardableResult public func setGlobal(_ key: String, values: [String], in context: Context) async -> Bool {
        await changeGlobal(key, .configSet(key: key, values: values), typed: values, in: context)
    }

    /// `-g config --unset -- <key>`, then the list again.
    @discardableResult public func unsetGlobal(_ key: String, in context: Context) async -> Bool {
        await changeGlobal(key, .configUnset(key: key), typed: [], in: context)
    }

    private func changeGlobal(
        _ key: String, _ command: Invocation.Command, typed: [String], in context: Context
    ) async -> Bool {
        guard !isWritingConfig else { return false }
        changingSetting = key
        settingRefusal = nil
        defer { changingSetting = nil }
        var failure: CLIError?
        do throws(CLIError) {
            let invocation = try Invocation(command, in: .personal, capabilities: context.capabilities)
            failure = try await context.client.run(invocation).failure()
        } catch {
            failure = error
        }
        await loadGlobalSettings(in: context)
        if key == Self.skillsShKey {
            await loadSkillsSh(in: context)
        }
        guard let failure else { return true }
        var message = ErrorCopy.message(for: failure, title: SettingsCopy.couldNotChange(key))
        message.details = nil
        if ConfigKey.mayHoldCredentials(key) {
            message = Self.masking(typed, in: message)
        }
        settingRefusal = SettingRefusal(key: key, message: message)
        return false
    }

    /// `message` with user names, passwords and the queries of typed values masked (`Redaction.credentials`): the
    /// CLI's refusal quotes a rejected `allow-sources` entry as typed (`"http://user:tok@host" is not packagist, …`).
    static func masking(_ values: [String], in message: UserMessage) -> UserMessage {
        func mask(_ text: String?) -> String? {
            text.map { Redaction.credentials(in: $0, typed: values) }
        }
        var message = message
        message.title = mask(message.title) ?? ""
        message.reason = mask(message.reason)
        message.action = mask(message.action)
        message.monoFragment = mask(message.monoFragment)
        return message
    }

    // MARK: - Adopted copies

    /// Settings › Advanced's "4 folders · 1.2 MB" for `folder` (where adopted copies go); nil until measured, or when
    /// the last measure was of another folder.
    public func adoptedSummary(of folder: URL) -> String? {
        guard let adopted, adopted.folder == folder else { return nil }
        return adopted.summary
    }

    /// Measures `folder` off the main actor (the walk visits every file) and keeps the summary.
    public func measureAdopted(at folder: URL) async {
        let summary = await measure(folder)
        adopted = (folder, summary)
    }

    /// The live measurer: `measure(_:)` on a detached task.
    public static let measureFolder: Measurer = { folder in
        await Task.detached { measure(folder) }.value
    }

    /// `4 folders · 1.2 MB`: the folders directly under `folder`, and the allocated size of every file below it;
    /// nil when `folder` cannot be listed.
    nonisolated static func measure(_ folder: URL) -> String? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        else { return nil }
        let folders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let walk = manager.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) {
            for case let url as URL in walk {
                let values = try? url.resourceValues(forKeys: keys)
                if values?.isRegularFile == true {
                    bytes += Int64(values?.totalFileAllocatedSize ?? 0)
                }
            }
        }
        return SettingsCopy.adoptedSummary(folders: folders.count, bytes: bytes)
    }

    // MARK: - GitHub token

    /// `auth set api.github.com --username oauth2` with `token` on stdin only. The caller clears its field before
    /// calling; nothing here keeps the token past the run, and the message of a failure never contains it.
    /// Returns whether the CLI stored it.
    @discardableResult public func signIn(token: String, in context: Context) async -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !isChangingToken else { return false }
        isChangingToken = true
        gitHubFailure = nil
        defer { isChangingToken = false }
        do throws(CLIError) {
            let invocation = try Invocation(
                .authSet(host: Self.gitHubHost, username: Self.gitHubUsername), in: .personal,
                capabilities: context.capabilities, stdin: .text(token))
            let result = try await context.client.run(invocation)
            if let failure = result.failure() {
                throw failure
            }
            gitHub = .signedIn
            tokenStorage = Self.storage(of: result)
            tokenWarnings = result.report.warnings.map { Self.mask(token, in: $0) }
            return true
        } catch {
            gitHubFailure = Self.redacting(
                token, in: ErrorCopy.message(for: error, title: SettingsCopy.couldNotSignIn))
            return false
        }
    }

    /// `auth remove api.github.com --username oauth2`: drops the token from the Keychain.
    public func signOut(in context: Context) async {
        guard !isChangingToken else { return }
        isChangingToken = true
        gitHubFailure = nil
        defer { isChangingToken = false }
        do throws(CLIError) {
            let invocation = try Invocation(
                .authRemove(host: Self.gitHubHost, username: Self.gitHubUsername), in: .personal,
                capabilities: context.capabilities)
            if let failure = try await context.client.run(invocation).failure() {
                throw failure
            }
            gitHub = .signedOut
            tokenStorage = nil
            tokenWarnings = []
        } catch {
            var message = ErrorCopy.message(for: error, title: SettingsCopy.couldNotSignOut)
            message.details = nil
            gitHubFailure = message
        }
    }

    /// `.keychain` when the CLI's confirmation names the osxkeychain helper.
    static func storage(of result: RunResult) -> TokenStorage {
        result.stdoutText.contains(keychainHelper) ? .keychain : .otherHelper
    }

    /// git's macOS Keychain credential helper.
    static let keychainHelper = "osxkeychain"

    static func mask(_ token: String, in text: String) -> String {
        text.replacingOccurrences(of: token, with: SettingsCopy.redacted)
    }

    /// `message` without its transcript and with every occurrence of `token` masked: the CLI prints only the
    /// token's length, but a helper's own error could echo what it was given.
    static func redacting(_ token: String, in message: UserMessage) -> UserMessage {
        func mask(_ text: String?) -> String? {
            text.map { Self.mask(token, in: $0) }
        }
        var message = message
        message.title = mask(message.title) ?? ""
        message.reason = mask(message.reason)
        message.action = mask(message.action)
        message.details = nil
        message.monoFragment = mask(message.monoFragment)
        return message
    }
}
