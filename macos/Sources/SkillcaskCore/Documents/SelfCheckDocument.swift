/// `self-check --json` (D51): the running CLI's version, the latest the tap's cask names (`null` when the cask held
/// no version the CLI could read), whether that is newer by SemVer precedence, and `managed`, who updates skillcask
/// on this machine (D61; absent before 0.12.1). Keys as D32 adds them; unknown ones are ignored.
public struct SelfCheckDocument: Decodable, Hashable, Sendable {
    public let version: String
    public let latest: String?
    public let newer: Bool
    /// `.some(nil)` for `"managed": null` (nobody), `nil` when the key is absent: an older CLI does not know.
    public let managed: String??

    enum CodingKeys: String, CodingKey {
        case version, latest, newer, managed
    }

    public init(version: String, latest: String?, newer: Bool, managed: String?? = nil) {
        self.version = version
        self.latest = latest
        self.newer = newer
        self.managed = managed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        latest = try c.decodeIfPresent(String.self, forKey: .latest)
        newer = try c.decode(Bool.self, forKey: .newer)
        managed = c.contains(.managed) ? .some(try c.decodeIfPresent(String.self, forKey: .managed)) : nil
    }

    /// `latest` read again strictly (`Version.init?(strict:)`): nil when it is null or anything but a plain
    /// version, so nothing else from the response reaches a URL or the screen.
    public var latestVersion: Version? {
        latest.flatMap(Version.init(strict:))
    }
}

/// What `CLIClient.selfCheck` learnt: the document, or that this CLI predates `self-check` (a path the user set in
/// Settings, older than the app); the bundled CLI always has it.
public enum SelfCheckOutcome: Hashable, Sendable {
    case checked(SelfCheckDocument)
    case unsupported
}

/// Which CLIs may be sent `self-check` at all. 0.9.0–0.10.1 route an unknown command to their plugin lookup
/// (`src/main.rs` `plugin`) and run `skillcask-self-check` from the child's `PATH` (which `EnvironmentPolicy`
/// extends with `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`): a program D35 does not list, whose stdout
/// would be taken for the document. So a CLI must be the app's bundled helper (built from the same tree as the app,
/// which has `self-check` even when a development bundle still reports 0.10.1) or report a version that ships it
/// (`Capabilities.Feature.selfCheck`).
public enum SelfCheckGate {
    public static func allows(binary: Locator.Choice?, capabilities: Capabilities) -> Bool {
        if case .bundled = binary {
            return true
        }
        return capabilities.supports(.selfCheck)
    }
}

extension CLIClient {
    /// Runs `self-check --json` outside any project (the CLI needs none), when `SelfCheckGate` allows `binary`;
    /// otherwise answers `.unsupported` without building the invocation. Exit 3 and every other failure throw as
    /// usual (`CLIError.failed` keeps the CLI's `error:` and `hint:` lines); under `GuardedClient` a run longer than
    /// 2 minutes throws `.timedOut`. A refusal of the command (`isUnknownSelfCheck`) still reads as `.unsupported`:
    /// a second line of defence behind the gate.
    public func selfCheck(
        binary: Locator.Choice?, capabilities: Capabilities
    ) async throws(CLIError)
        -> SelfCheckOutcome
    {
        guard SelfCheckGate.allows(binary: binary, capabilities: capabilities) else { return .unsupported }
        let result = try await run(Invocation(.selfCheck, in: .personal, capabilities: capabilities))
        if let failure = result.failure(), Self.isUnknownSelfCheck(failure) {
            return .unsupported
        }
        let document = try result.document(SelfCheckDocument.self)
        // A CLI that could not read `updates.managed` warns and prints null: that says nothing about the machine.
        if StderrReport(parsing: result.stderr).warnings.contains(where: { $0.hasPrefix("updates.managed unknown") }) {
            return .checked(
                SelfCheckDocument(version: document.version, latest: document.latest, newer: document.newer))
        }
        return .checked(document)
    }

    /// An older CLI's refusal of the word `self-check`: `unknown command "self-check" (no skillcask-self-check on
    /// PATH)` with exit 1 (`src/main.rs` `plugin`, every release since 0.9.0), or clap's `unrecognized subcommand
    /// 'self-check'` should a release parse it as a usage error (exit 1 here, 2 in clap's default).
    static func isUnknownSelfCheck(_ error: CLIError) -> Bool {
        guard case .failed(let code, let message, _, _) = error, code == .problem || code == .signIn else {
            return false
        }
        return message.hasPrefix(#"unknown command "self-check""#)
            || message.hasPrefix("unrecognized subcommand 'self-check'")
    }
}
