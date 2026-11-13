import Foundation
import SkillcaskCore
import SkillcaskDomain

/// What a failure says on screen: one sentence of what went wrong, one of what to do, then
/// "Details" with the raw transcript. Exit codes and command names never appear in the sentences; the raw text
/// lives in `details` only. Built by `ErrorCopy`; the `FailureBanner` draws it.
public struct UserMessage: Hashable, Sendable {
    /// The button a banner offers besides Details and Dismiss, decided by the kind of failure.
    public enum Remedy: Hashable, Sendable {
        /// A network problem: "Retry" (manual, never automatic).
        case retry
        /// A sign-in problem: "Open Settings", where the GitHub token lives.
        case signIn
    }

    /// One sentence, bold on the banner: what went wrong (`Couldn’t sync sql-review.`).
    public var title: String
    /// The CLI's own sentence when `title` names what the app was doing instead (`The source … needs you to sign in.`).
    public var reason: String?
    /// One sentence: what to do (the CLI hint, reworded only through `ErrorCopy`'s table).
    public var action: String?
    /// The full transcript for the Details disclosure; nil when there is nothing beyond the sentences.
    public var details: String?
    /// The banner's tint: `.error` for most failures, `.warning` for a policy refusal or a name clash, `.neutral`
    /// for a cancellation.
    public var severity: Severity
    /// The button the banner offers besides Details and Dismiss (Retry, Open Settings); nil when the only fix
    /// is what `action` says.
    public var remedy: Remedy?
    /// A hash mismatch: red border, "Nothing was changed.", never retried automatically.
    public var isIntegrity: Bool
    /// A part of `reason` or `action` the user will meet verbatim in a file, drawn in SF Mono (`packagist, acme`
    /// in the policy refusal of AddSkill-States); the first occurrence only.
    public var monoFragment: String?
    /// A read the app stopped at its time limit (`CLIError.timedOut`): Retry, but a clock, not the network mark.
    public var isTimeout = false

    public init(
        title: String, reason: String? = nil, action: String? = nil, details: String? = nil,
        severity: Severity = .error, remedy: Remedy? = nil, isIntegrity: Bool = false, monoFragment: String? = nil
    ) {
        self.title = title
        self.reason = reason
        self.action = action
        self.details = details
        self.severity = severity
        self.remedy = remedy
        self.isIntegrity = isIntegrity
        self.monoFragment = monoFragment
    }
}

/// `CLIError` → `UserMessage`: the English of every way a run can fail, with the board sentences where a board
/// shows the case (Running, Components, AddSkill-States, Onboarding). Views never build this text themselves.
public enum ErrorCopy {
    // MARK: - Mapping

    /// The message for `error`. With `title`, the caller names what it was doing (`Couldn’t sync sql-review.`)
    /// and the CLI's sentence moves to `reason`, as the Running board lays a banner out.
    public static func message(for error: CLIError, title: String? = nil) -> UserMessage {
        var message = base(for: error)
        if let title {
            message.reason = message.title
            message.title = title
        }
        return message
    }

    /// The Add Skill name clash (AddSkill-States): a warning, not an error, since the fix is a rename.
    public static func nameClash(existing: String, existingPackage: String, newPackage: String) -> UserMessage {
        UserMessage(
            title: "A skill named \(existing) already exists in this project.",
            reason: "It comes from \(existingPackage).",
            action: "Install the new one from \(newPackage) under another name so both can be linked.",
            severity: .warning)
    }

    /// Invented: over the Add Skill preview of a `github:` source whose package this scope has from another source
    /// (`composer`, `git`, as `info` names them): `add` replaces that skills.toml entry (`src/commands.rs`
    /// `add_vcs`). `removed` are the skills known to go with it. A warning: Add still works.
    public static func entryReplaced(package: String, source: String, removed: [String], personal: Bool) -> UserMessage
    {
        let scope = personal ? ShellCopy.personalScope : "this project"
        let from = source == "git" ? "a git URL" : source == "composer" ? "a Composer repository" : source
        let replaces = "Add replaces that entry with the GitHub repository"
        return UserMessage(
            title: "\(package) is already in \(scope) from \(from).",
            reason: removed.isEmpty ? "\(replaces)." : "\(replaces) and removes \(AddSkillCopy.some(removed)).",
            severity: .warning)
    }

    // MARK: - Sentences

    /// The integrity sentence the board insists on (Running, Components): appended when the CLI did not say it.
    public static let nothingWasChanged = "Nothing was changed."
    /// The sign-in action when the CLI gave no hint (Components board).
    public static let signInAction = "Add a GitHub token in Settings, then try again."
    /// The network action when the CLI gave no hint (AddSkill-States, ReviewUpdate-States).
    public static let networkAction = "Check your connection and try again."
    /// The integrity action when the CLI gave no hint (Components board).
    public static let integrityAction = "This can mean the source was tampered with."
    public static let cancelled = "Cancelled."
    /// S13, CLI missing (Onboarding board, short form).
    public static let binaryMissingTitle = "Skillcask needs its command-line tool."
    public static let binaryMissingReason = "It isn’t installed yet, or it isn’t on your path."
    public static let binaryMissingAction = "Install it with Homebrew, or locate it in Settings."
    /// S13, CLI too old (Onboarding-States board, short form).
    public static let tooOldTitle = "Skillcask needs a newer command-line tool."
    public static let tooOldReason = "This version of the app reads data the installed tool does not produce yet."
    public static let tooOldAction = "Upgrade it with Homebrew."
    /// `--version` printed something that is not a skillcask version line: the path points at another program.
    public static let unreadableVersionTitle = "The command-line tool at the configured path isn’t Skillcask."
    public static let unreadableVersionAction = "Check its path in Settings."
    /// Invented (no board shows it): the configured path is the Skillcask app itself (`CLIError.binaryIsApp`).
    public static let binaryIsAppTitle = "That file is the Skillcask app, not the command-line tool."
    /// Invented, with `binaryIsAppTitle`.
    public static let binaryIsAppAction = "Choose the skillcask command-line tool instead."
    public static let unsupportedTitle = "The installed command-line tool can’t do this yet."
    public static let unsupportedAction = "Upgrade it to a newer version."
    public static let invalidInvocationTitle = "Skillcask couldn’t build this command."
    public static let launchFailedTitle = "The command-line tool couldn’t be started."
    public static let launchFailedAction = "Check its path in Settings."
    public static let killedTitle = "The command-line tool stopped unexpectedly."
    public static let noDocumentTitle = "The command-line tool answered with nothing."
    public static let noDocumentAction = "Try again."
    public static let decodeTitle = "The command-line tool answered with something this app can’t read."
    public static let decodeAction = "Update the app or the tool so they match."
    public static let outputTooLargeTitle = "The command-line tool’s answer was too large to read."
    /// Invented (no board shows it): a read-only command passed `GuardedClient.readTimeout` and the app stopped it.
    public static let timedOutTitle = "The command-line tool didn’t answer in time."
    /// Invented, with `timedOutTitle`: `Skillcask stopped it after 2 minutes. Try again.` (15 minutes for a read
    /// that talks to registries; seconds below a minute).
    public static func timedOutAction(after limit: Duration) -> String {
        let seconds = limit.components.seconds
        let span =
            seconds >= 60 && seconds % 60 == 0
            ? (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")
            : (seconds == 1 ? "1 second" : "\(seconds) seconds")
        return "Skillcask stopped it after \(span). Try again."
    }
    /// What `title` becomes when the CLI's message is blank.
    static let blankMessage = "Something went wrong."

    /// The CLI hints the app rewords ("reworded only when a table entry exists, else verbatim"), keyed by
    /// the exact hint `src/*.rs` prints; the UI words are the app's (install → Sync, doctor --fix → Repair, …).
    static let rewordedHints: [String: String] = [
        "run skillcask install": "Sync this project.",
        "run skillcask install locally and commit skills.lock": "Sync locally and commit skills.lock.",
        "run skillcask update": "Update the skills in this project.",
        "run skillcask init": "Set up this folder.",
        "run skillcask --global init": "Set up your personal skills.",
        "skillcask doctor --fix repairs links and the gitignore block":
            "Repair fixes the links and the gitignore block.",
        "manage personal skills with --global, e.g. skillcask --global install":
            "Personal skills live under My Skills.",
    ]

    /// The CLI hint as the banner's action: the table's wording when it has one, else the hint itself as a sentence.
    public static func action(forHint hint: String?) -> String? {
        guard let hint else { return nil }
        let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return rewordedHints[trimmed] ?? rewordedByPattern(trimmed) ?? sentence(trimmed)
    }

    /// The hints whose wording carries a name (a block file, the manifest and lock of a merge conflict), reworded
    /// by pattern so the names stay and the command does not: `src/commands.rs` doctor, `src/lock.rs` parse.
    static func rewordedByPattern(_ hint: String) -> String? {
        if let match = hint.wholeMatch(of: #/skillcask --global doctor --fix repairs links and (?<file>.+)/#) {
            return "Repair fixes the links and \(match.file)."
        }
        let conflict =
            #/resolve (?<manifest>\S+) first, keep either side of (?<lock>\S+) \(.*\), then run skillcask install; it locks what that side lacks/#
        if let match = hint.wholeMatch(of: conflict) {
            return
                "Resolve \(match.manifest) first and keep either side of \(match.lock), then Sync; it locks what that side lacks."
        }
        return nil
    }

    /// `packagist, acme` out of the policy refusal `Allowed sources are packagist, acme, set in …` (AddSkill-States
    /// draws the list in SF Mono); nil when the message is worded otherwise.
    static func policyMonoFragment(_ message: String) -> String? {
        guard let match = message.firstMatch(of: #/Allowed sources are (?<list>.+?), set in/#) else { return nil }
        return String(match.list)
    }

    /// `text` as one sentence: a capital first letter when the first word is a plain word (a package name, path or
    /// host keeps its spelling), a full stop when nothing ends it. Blank text reads `Something went wrong.`
    public static func sentence(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return blankMessage }
        let firstWord = trimmed.prefix { !$0.isWhitespace }
        if firstWord.allSatisfy(\.isLetter) {
            trimmed = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        if let last = trimmed.last, !terminalPunctuation.contains(last) {
            trimmed.append(".")
        }
        return trimmed
    }

    private static let terminalPunctuation: Set<Character> = [".", "!", "?", "…"]

    // MARK: - Cases

    private static func base(for error: CLIError) -> UserMessage {
        switch error {
        case .failed(let code, let message, let hint, let stderr):
            return failed(code: code, message: message, hint: hint, stderr: stderr)
        case .cancelled:
            return UserMessage(title: cancelled, severity: .neutral)
        case .unreadableVersion(let output):
            return UserMessage(
                title: unreadableVersionTitle, action: unreadableVersionAction, details: details(output))
        case .binaryMissing(let searched):
            return UserMessage(
                title: binaryMissingTitle, reason: binaryMissingReason, action: binaryMissingAction,
                details: details(searched.joined(separator: "\n")))
        case .binaryIsApp(let path):
            return UserMessage(title: binaryIsAppTitle, action: binaryIsAppAction, details: details(path))
        case .tooOld(let found, let needs):
            return UserMessage(
                title: tooOldTitle, reason: tooOldReason, action: tooOldAction,
                details: "Found \(found)\nNeeded \(needs) or newer")
        case .unsupported(let feature):
            return UserMessage(title: unsupportedTitle, action: unsupportedAction, details: details(feature))
        case .invalidInvocation(let text):
            return UserMessage(title: invalidInvocationTitle, details: details(text))
        case .launchFailed(let text):
            return UserMessage(title: launchFailedTitle, action: launchFailedAction, details: details(text))
        case .killed(let signal):
            return UserMessage(title: killedTitle, details: "Signal \(signal)")
        case .noDocument:
            return UserMessage(title: noDocumentTitle, action: noDocumentAction)
        case .decode(let description, let raw):
            let text = String(decoding: raw, as: UTF8.self)
            return UserMessage(
                title: decodeTitle, action: decodeAction,
                details: details([description, text].filter { !$0.isEmpty }.joined(separator: "\n\n")))
        case .outputTooLarge(let limit):
            return UserMessage(title: outputTooLargeTitle, details: "Limit: \(limit) bytes")
        case .timedOut(let limit):
            var message = UserMessage(title: timedOutTitle, action: timedOutAction(after: limit), remedy: .retry)
            message.isTimeout = true
            return message
        }
    }

    private static func failed(code: ExitCode, message: String, hint: String?, stderr: String) -> UserMessage {
        let title = sentence(message)
        let hintAction = action(forHint: hint)
        let transcript = details(stderr)
        switch code {
        case .integrity:
            let said = message.localizedCaseInsensitiveContains("nothing was changed")
            return UserMessage(
                title: title, reason: said ? nil : nothingWasChanged, action: hintAction ?? integrityAction,
                details: transcript, isIntegrity: true)
        case .signIn:
            return UserMessage(title: title, action: hintAction ?? signInAction, details: transcript, remedy: .signIn)
        case .network:
            return UserMessage(title: title, action: hintAction ?? networkAction, details: transcript, remedy: .retry)
        case .problem:
            let policy = isPolicyRefusal(message)
            return UserMessage(
                title: title, action: hintAction, details: transcript, severity: policy ? .warning : .error,
                monoFragment: policy ? policyMonoFragment(message) : nil)
        case .file, .other:
            return UserMessage(title: title, action: hintAction, details: transcript)
        }
    }

    /// A refusal by the project's policy (AddSkill-States draws it amber: the fix is a conversation, not a repair).
    private static func isPolicyRefusal(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("allowed source") || lower.contains("policy.") || lower.contains("allow-sources")
    }

    private static func details(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
