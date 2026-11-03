import Foundation
import SkillcaskCore

/// The words of the S13 onboarding sheet (Onboarding and Onboarding-States boards), verbatim, and the links it
/// opens. `CLIOnboardingSheet` draws them; views never spell them. The first-launch banner and the sidebar hint
/// reuse `StripCopy.notManagedTitle(count:)` and `EmptyCopy` (`noProjectsTitle`, `openFolder`, `findProjects`).
///
/// The Homebrew commands are the release's: `dist-workspace.toml` publishes the formula `skillcask` to the tap
/// `GetResponse/homebrew-tap` (README "Install": `brew install getresponse/tap/skillcask`). The upgrade command names the
/// tap too (`brew upgrade getresponse/tap/skillcask`, a decision), where the board writes the bare
/// `brew upgrade skillcask`, which would be ambiguous if a core formula of that name ever existed. Needed is
/// `Capabilities.minimum` (0.9.4), where the board writes 0.9.0.
///
/// Invented (no board source): `notATool`, `locatedTooOld(found:needs:)` (why Locate… refused a file) and
/// `detecting` (the spinner's accessibility label while Try Again re-detects).
public enum OnboardingCopy {
    // MARK: - Links

    /// Learn more: the project's README (`Cargo.toml` `repository`).
    public static let readme = URL(string: "https://github.com/GetResponse/skillcask") ?? URL(fileURLWithPath: "/")
    /// "Other ways to install": the README's Install section.
    public static let installSection =
        URL(string: "https://github.com/GetResponse/skillcask#install") ?? URL(fileURLWithPath: "/")

    // MARK: - CLI missing (Onboarding)

    public static let missingTitle = "Skillcask needs its command-line tool"
    /// The tool's name, drawn in mono inside `missingBody`.
    public static let toolName = "skillcask"
    public static let missingBody =
        "The app shows what the skillcask tool reports and runs it for you; it has no logic of its own. It isn’t "
        + "installed yet, or it isn’t on your path."
    public static let installStep = "Install it with Homebrew"
    public static let installCommand = "brew install getresponse/tap/skillcask"
    public static let noHomebrew = "No Homebrew?"
    public static let otherWays = "Other ways to install"
    public static let inTheReadme = "are in the README."
    public static let comeBackStep = "Then come back here"
    /// The folders the board names in `comeBackBody`, drawn in mono (`EnvironmentPolicy.extraPaths`).
    public static let usualPlaces = ["/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin"]
    public static let comeBackLead = "Skillcask looks in the usual places ("
    public static let comeBackTail = "). Installed somewhere else? Point to it with Locate…."

    // MARK: - CLI too old (Onboarding-States)

    public static let tooOldTitle = "Skillcask needs a newer command-line tool"
    public static let tooOldBody = "This version of the app reads data the installed tool does not produce yet."
    public static let found = "Found"
    public static let needed = "Needed"
    /// `0.7.2 at /opt/homebrew/bin/skillcask`; the version alone when the path is unknown.
    public static func foundValue(_ version: Version, at path: String?) -> String {
        guard let path else { return "\(version)" }
        return "\(version) at \((path as NSString).abbreviatingWithTildeInPath)"
    }
    /// `0.9.4 or newer`.
    public static func neededValue(_ version: Version) -> String {
        "\(version) or newer"
    }
    public static let upgradeStep = "Upgrade with Homebrew"
    public static let upgradeCommand = "brew upgrade getresponse/tap/skillcask"
    public static let thenTryAgain = "Then Try Again"
    public static let differentCopy = "A different copy somewhere else? Use Locate…."

    // MARK: - Footer and controls (both boards)

    public static let learnMore = "Learn more"
    public static let locate = "Locate…"
    public static let tryAgain = "Try Again"
    public static let copy = "Copy"

    // MARK: - Invented

    /// Locate… refused a file that is not the tool (not executable, or `--version` printed no version).
    public static let notATool = "That file isn’t the skillcask command-line tool."
    /// Locate… refused a copy older than the app needs: `That copy is 0.8.0; Skillcask needs 0.9.4 or newer.`
    public static func locatedTooOld(found: Version, needs: Version) -> String {
        "That copy is \(found); Skillcask needs \(neededValue(needs))."
    }
    /// The spinner's accessibility label while Try Again or Locate… re-detects.
    public static let detecting = "Looking for the command-line tool…"

    /// Why Locate… refused `error`.
    public static func locateFailure(_ error: CLIError) -> String {
        switch error {
        case .tooOld(let found, let needs): locatedTooOld(found: found, needs: needs)
        case .binaryIsApp: ErrorCopy.binaryIsAppTitle
        default: notATool
        }
    }
}
