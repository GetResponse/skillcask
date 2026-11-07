import Foundation
import SkillcaskCore

/// The words of the Settings window (S14: Settings and Settings-States boards). Board strings are verbatim; the
/// GitHub limits (60 an hour signed out, 5 000 with a token) are GitHub's documented REST API limits, so the board's
/// sentence stays as drawn.
///
/// Invented (no board draws them): `chosenInSettings`, `toolNotFound`, `chooseTool`, `skillsShNotSet`,
/// `couldNotSaveSkillsSh`, `skillsShNotSaved`, `gitHubUnknown`, `gitHubSignedIn`, `signOut`, `unknownNote`,
/// `couldNotSignIn`, `couldNotSignOut`, `redacted`, `tokenStored`, `tokenStoredByHelper`, `tokenNoteNeutral`,
/// `credentialsNotSaved`, `refusedVariable`, `removeVariable` (the board's
/// aria-label "Remove" with the name), `adoptedSummary(folders:bytes:)`'s singular and empty forms, `noAdopted`,
/// and the forms of `sourcesSearched(_:project:)` without a project or without project sources.
///
/// Global (no board draws this tab; every string in its MARK is invented, after the maintainer's Settings window
/// for `-g config` in upstream `eca0f53`): `global`, `settingLabel(_:)`, `layer(_:)`, `notSet`, `edit`, `unset`,
/// `cancel`, `separateEntries`, `enforcedNote`, `unsetEnforcedFirst`, `environmentNote(variable:)`, `redactedSourcesNote`,
/// `globalNeedsCLI`, `couldNotReadGlobal`, `couldNotChange(_:)`, `globalFooter`, and
/// Advanced's `policyNote`, which replaced the board's read-only sentence.
public enum SettingsCopy {
    // MARK: - Tabs

    public static let general = "General"
    public static let search = "Search"
    public static let updates = "Updates"
    public static let advanced = "Advanced"
    public static let global = "Global"

    // MARK: - General

    public static let commandLineTool = "Command-line tool:"
    public static let choose = "Choose…"
    /// The open panel's button for Choose…. Invented.
    public static let chooseTool = "Use This Tool"
    public static let foundAutomatically = "found automatically"
    /// The tool was picked with Choose…. Invented.
    public static let chosenInSettings = "chosen in Settings"
    public static let useDetected = "Use the detected one"
    /// No tool located (the onboarding sheet explains). Invented.
    public static let toolNotFound = "Not found"

    /// `Version 0.9.4 · found automatically` (the board's line before its link).
    public static func toolLine(version: Version, configured: Bool) -> String {
        "Version \(version) · " + (configured ? chosenInSettings : foundAutomatically)
    }

    public static let openAtLaunch = "Open at launch:"
    public static let lastScopeUsed = "Last scope used"
    /// `Or always My Skills.`
    public static let openAtLaunchNote = "Or always \(ShellCopy.personalScope)."

    public static let recentProjects = "Recent projects:"
    public static let clearRecent = "Clear Recent"
    public static let privacy =
        "Nothing here leaves your Mac. The app has no account, no telemetry and no cloud features."

    // MARK: - Search

    public static let alsoSearchSkillsSh = "Also search skills.sh:"

    /// The sentence beside the switch; the view draws `skillsShStored(_:)` in mono where the board does.
    public static let skillsShNote =
        "Your search text is sent to skills.sh when you use Add Skill…. Packagist and your project’s own sources are always searched."

    /// `Stored as search.skills-sh = true in config.toml.`, split around the mono key; `from` is the layer
    /// `config` names (`system config.toml` for D60's file).
    public static let storedAs = "Stored as"
    public static func storedIn(_ from: String?) -> String {
        "in \(from ?? "config.toml")."
    }

    /// The mono fragment: `search.skills-sh = true`.
    public static func skillsShStored(_ on: Bool) -> String {
        "search.skills-sh = \(on)"
    }

    /// config.toml does not set it. Invented.
    public static let skillsShNotSet = "Not set in config.toml yet; Add Skill… asks the first time you search."
    /// Under the tool line while a sheet or the Remove alert is open in the main window: Choose… and "Use the
    /// detected one" would rebuild what it works on. Invented.
    public static let closeSheetFirst = "Close the open sheet in the main window to change the tool."
    /// Invented.
    public static let couldNotSaveSkillsSh = "Couldn’t save the skills.sh setting."
    /// Why, when `config` itself succeeded but reading the key back gave another value. Invented.
    public static let skillsShNotSaved = "config.toml did not change."

    public static let sourcesSearchedLabel = "Sources searched:"

    /// `Packagist, plus the sources of the open project (acme for api). GitHub results appear only where policy
    /// allows them.`; without project sources the parenthesis goes (invented form).
    public static func sourcesSearched(_ sources: [String], project: String?) -> String {
        let named = project.flatMap { sources.isEmpty ? nil : " (\(sources.joined(separator: ", ")) for \($0))" } ?? ""
        return "Packagist, plus the sources of the open project\(named). "
            + "GitHub results appear only where policy allows them."
    }

    /// The names the sentence gives for a project: its allowed sources, without Packagist and GitHub, which the
    /// sentence names apart.
    public static func projectSources(_ repositories: [StatusDocument.Repository]) -> [String] {
        repositories.filter { $0.allowed && $0.name != "packagist" && $0.type != "github" }.map(\.name)
    }

    public static let searchFooter =
        "Results are never ranked or filtered by the app; order and install counts come from the sources as the command-line tool returns them."

    // MARK: - Updates

    public static let checkOnOpen = "Check for updates when a project opens:"
    public static let checkOnOpenNote = "Asks each source what is newer. Off, you check with Refresh ⌘R."
    public static let gitHub = "GitHub:"
    public static let signedOut = "Signed out"
    /// No command tells whether a token is stored without returning it. Invented.
    public static let gitHubUnknown = "Unknown"
    /// This session stored a token. Invented.
    public static let gitHubSignedIn = "Signed in"
    public static let signIn = "Sign in to GitHub…"
    /// Runs `auth remove`. Invented.
    public static let signOut = "Sign Out"
    public static let signedOutNote =
        "Signed out, GitHub allows 60 checks per hour from this Mac. With many GitHub-sourced skills, checks can stall until the hour ends. A token raises the limit to 5 000."
    /// The same note when the app cannot know whether a token is stored. Invented (the board's first clause
    /// reworded).
    public static let unknownNote =
        "Without a token, GitHub allows 60 checks per hour from this Mac. With many GitHub-sourced skills, checks can stall until the hour ends. A token raises the limit to 5 000."
    public static let gitHubToken = "GitHub token:"
    public static let tokenPlaceholder = "ghp_… or a fine-grained token"
    public static let save = "Save"
    public static let tokenNote =
        "Stored in your Keychain by the command-line tool; the app never reads it back. Needs only public-repo read access."
    /// The token field's note before the helper is known (the board's sentence claims the Keychain, which holds
    /// only for git's osxkeychain helper). Invented.
    public static let tokenNoteNeutral =
        "Stored with git's credential helper by the command-line tool; the app never reads it back. "
        + "Needs only public-repo read access."
    /// After a Save that the CLI stored with osxkeychain. Invented.
    public static let tokenStored = "Token stored in your Keychain."
    /// After a Save stored by another helper. Invented.
    public static let tokenStoredByHelper = "Token stored by git's credential helper."
    /// Invented.
    public static let couldNotSignIn = "Couldn’t sign in to GitHub."
    /// Invented.
    public static let couldNotSignOut = "Couldn’t sign out of GitHub."
    /// What replaces a token if any text would ever contain it. Invented.
    public static let redacted = "••••"

    // MARK: - Global

    /// The row label of a `config` key; a key a newer CLI adds is labelled by itself.
    public static func settingLabel(_ key: String) -> String {
        switch key {
        case "policy.min-release-age": "Minimum release age:"
        case "policy.allow-ranges": "Allow version ranges:"
        case "policy.packagist": "Use Packagist:"
        case "policy.github-requires": "Allow GitHub dependencies:"
        case "policy.allow-sources": "Allowed sources:"
        case "policy.deny-patterns": "Refuse risky patterns:"
        case "policy.deny-packages": "Refused packages:"
        case "policy.enforce": "Enforced settings:"
        case "agents.targets": "Agents:"
        case "search.skills-sh": alsoSearchSkillsSh
        default: "\(key):"
        }
    }

    /// Where the value comes from, after the mono key: `policy.min-release-age · enforced in config.toml`.
    public static func layer(_ layer: ConfigLayer?) -> String {
        switch layer {
        case .configFile?: "from config.toml"
        case .enforced?: "enforced in config.toml"
        case .system?: "from the system config.toml"
        case .systemEnforced?: "enforced in the system config.toml"
        case .environment?: "from the environment"
        case .builtIn?: "built-in default"
        case .manifest?: "from skills.toml"
        case .other(let name)?: "from \(name)"
        case nil: "not set"
        }
    }

    /// The value of a key nothing sets.
    public static let notSet = "Not set"
    public static let edit = "Edit"
    /// Runs `-g config --unset`.
    public static let unset = "Unset"
    public static let cancel = "Cancel"
    /// Under a list being edited.
    public static let separateEntries = "Separate entries with commas; an empty list removes the key."
    /// Under a key `policy.enforce` lists.
    public static let enforcedNote = "Enforced: no project can loosen it."
    /// After `enforcedNote`: the row has no Unset, since the CLI refuses to unset a key `policy.enforce` lists.
    public static let unsetEnforcedFirst = "To unset it, remove it from Enforced settings first."

    /// Under a key the system config.toml enforces (D60): the row is read-only. Invented.
    public static let systemEnforcedNote =
        "Your organisation enforces this in the system config.toml; ask whoever manages this Mac to change it."

    /// Under a key a `SKILLCASK_*` variable sets: the row is read-only.
    public static func environmentNote(variable: String?) -> String {
        let named = variable.map { "\($0) is set" } ?? "It is set"
        return "\(named) in the command-line tool’s environment, which wins over config.toml; a change here has "
            + "no effect while it is set."
    }

    /// Under `allow-sources` with a URL entry: the row is read-only.
    public static let redactedSourcesNote =
        "URLs are shown without user names, passwords or queries, so saving from here would drop them. Change "
        + "this in config.toml (Advanced › Open config.toml)."

    /// Before the CLI is located.
    public static let globalNeedsCLI = "Find the command-line tool in General to read these settings."
    public static let couldNotReadGlobal = "Couldn’t read the global settings."

    public static func couldNotChange(_ key: String) -> String {
        "Couldn’t change \(key)."
    }

    public static let globalFooter =
        "Every project starts from these settings of config.toml. Each change runs skillcask -g config, which "
        + "checks it before writing the file, and the list is read again afterwards."

    // MARK: - Advanced

    public static let environmentTitle = "Environment variables for the command-line tool"
    public static let name = "Name"
    public static let value = "Value"
    public static let addVariable = "+ Add Variable"
    /// The remove button's glyph.
    public static let minus = "−"
    public static let environmentNote = "Applied to every run; the Activity log shows them."
    /// The board's aria-label, with the row's name. Invented.
    public static func removeVariable(_ name: String) -> String {
        name.isEmpty ? "Remove" : "Remove \(name)"
    }

    /// A value with credentials (URL userinfo or a token format). Invented.
    public static let credentialsNotSaved =
        "A value with a user name, password or token in it is used this session only and never saved; the table "
        + "masks it."

    /// A row the policy refuses. Invented.
    public static let refusedVariable =
        "Not applied: names use A–Z, 0–9 and _, and variables for policy, credentials, hosts, TLS, CI, git and "
        + "the app’s own output can’t be set here."

    public static let configurationFile = "Configuration file:"
    public static let openConfig = "Open config.toml"
    public static let adoptedCopies = "Adopted copies:"
    public static let revealInFinder = "Reveal in Finder"
    /// The adopted folder does not exist yet. Invented.
    public static let noAdopted = "None yet"

    /// `4 folders · 1.2 MB` (singular form invented).
    public static func adoptedSummary(folders: Int, bytes: Int64) -> String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(folders) \(folders == 1 ? "folder" : "folders") · \(size)"
    }

    public static let activity = "Activity:"
    public static let showActivity = "Show Activity ⌥⌘L"
    public static let activityNote = "Only this session; nothing is written to disk by the app."
    /// Points to Settings › Global (invented, replacing the board's read-only sentence once `-g config` came):
    /// a project's skills.toml overrides a key config.toml sets, but must not differ from an enforced one
    /// (`src/policy.rs` `resolve`).
    public static let policyNote =
        "Global settings, including policy, are changed in Settings › Global through skillcask -g config; a "
        + "project’s skills.toml can override them, except the ones config.toml enforces."
}
