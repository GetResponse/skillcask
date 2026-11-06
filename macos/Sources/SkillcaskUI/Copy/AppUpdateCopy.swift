import Foundation
import SkillcaskCore
import SkillcaskUpdates

/// The words of the app-update check (D51): the sidebar card (U1), the app menu item and the manual check's alerts
/// (U4). It differs from the boards (DESIGN.md G14): no release date (the cask has none), no command-line tool
/// card, and the consent prompt of D51.
public enum AppUpdateCopy {
    // MARK: - Card (U1)

    /// What VoiceOver reads for the card and announces once when it appears.
    public static let cardLabel = "Skillcask update available"
    public static let consentLabel = "Daily update check"
    public static let awaitingLabel = "Waiting for the Skillcask update"

    public static func availableTitle(_ version: Version) -> String {
        "Skillcask \(version) is available"
    }

    public static func availableSubtitle(installed: Version) -> String {
        "You have \(installed)"
    }

    /// The icon-only × on the card.
    public static let hide = "Hide until the next version"
    public static let seeWhatsNew = "See What’s New…"

    public static let consentTitle = "Check for new versions daily?"
    /// Decision 3: what the daily check asks, of whom, and what it never sends.
    public static let consentBody =
        "Skillcask asks GitHub (raw.githubusercontent.com) once a day, with no account, project or skill information."
    public static let checkDaily = "Check Daily"
    public static let notNow = "Not Now"

    public static let awaitingTitle = "Waiting for the update"
    public static let awaitingBody = "Command copied. After Homebrew finishes, quit and reopen Skillcask."

    // MARK: - Sheet (U2/U3)

    public static let releaseNotes = "Release Notes on GitHub"
    /// The sheet's hidden Esc button.
    public static let close = "Close"

    /// The header's pill: how this copy was installed.
    public static func pill(_ method: InstallMethod) -> String {
        switch method {
        case .homebrew: "Installed with Homebrew"
        case .direct: "Installed from a download"
        case .translocated: "Running from a temporary copy"
        }
    }

    public static let runInTerminal = "Run in Terminal"
    /// Under the command: the cask has no `uninstall quit:`, so Homebrew does not quit the app.
    public static let homebrewCaption =
        "Homebrew replaces Skillcask while it runs; quit and reopen it afterwards. Nothing in your projects, "
        + "skills.toml or skills.lock changes."
    public static let copy = "Copy"

    /// What VoiceOver reads for a command's Copy button.
    public static func copyLabel(_ command: String) -> String {
        "Copy command: \(command)"
    }

    public static let howToUpdateTitle = "How to update"
    /// Above the organisation's own words when it updates the app (D61).
    public static let managedTitle = "Updates are managed by your organisation"

    /// The direct-download steps, naming the release's zip; nil (a version that is not strict, so no zip name) says
    /// the macOS zip.
    public static func howToUpdate(zip: String?) -> String {
        "Download \(zip ?? "the macOS zip") from the release page, quit Skillcask, unzip it and drag Skillcask into "
            + "Applications, replacing the old copy. If you installed it with skillcask-app-installer.sh, run that again "
            + "instead."
    }

    /// The temporary-copy callout: the bold lead, then why it matters.
    public static let translocatedLead = "Skillcask is running from a temporary copy."
    public static let translocatedBody =
        "macOS moved it there because it was opened straight from Downloads. Updating that copy would be lost on "
        + "the next restart."
    public static let doThisFirst = "Do this first"
    public static let doThisFirstBody =
        "Quit Skillcask, move it from Downloads into Applications, and open it from there. The update will then "
        + "show the right steps."

    /// A footer button's title.
    public static func title(for action: AppUpdateStore.SheetAction) -> String {
        switch action {
        case .copyCommand: "Copy Command"
        case .copyAndOpenTerminal: "Copy and Open Terminal"
        case .openReleasePage: "Open Release Page"
        case .showInFinder: "Show in Finder"
        case .skip: "Skip This Version"
        case .remindTomorrow: "Remind Me Tomorrow"
        }
    }

    // MARK: - Settings › Updates (U5)

    public static let appGroup = "Skillcask app"
    public static let installedLabel = "Installed:"
    public static let dailyLabel = "Check for new versions daily:"
    /// Decision 3's privacy line beside the switch: the consent card's sentence.
    public static let dailyNote = consentBody
    public static let lastCheckedLabel = "Last checked:"
    public static let checkNow = "Check Now"
    public static let skippedLabel = "Skipped version:"
    public static let reset = "Reset"
    public static let never = "Never"
    public static let none = "None"
    /// `Check Now` waits for the command-line tool (onboarding, a re-detection).
    public static let checkNeedsCLI = "Available once the command-line tool is ready."
    /// The CLI chosen in Settings › General predates `self-check` (`SelfCheckGate`).
    public static let checkNeedsNewerCLI =
        "The command-line tool chosen in General is too old to check for updates."

    /// `Skillcask 0.10.2 · Homebrew`.
    public static func installedLine(_ version: Version, _ method: InstallMethod) -> String {
        let how =
            switch method {
            case .homebrew: "Homebrew"
            case .direct: "download"
            case .translocated: "temporary copy"
            }
        return "Skillcask \(version) · \(how)"
    }

    /// `Never`, `Today at 09:14`, `Yesterday at 09:14`, else `29 Oct at 09:14` (calendar days in `timeZone`).
    public static func lastChecked(_ date: Date?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let date else { return never }
        let calendar = Formatters.calendar(timeZone)
        let days =
            calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now))
            .day ?? 0
        let time = Formatters.time(date, timeZone: timeZone)
        switch days {
        case ..<1: return "Today at \(time)"
        case 1: return "Yesterday at \(time)"
        default: return "\(Formatters.dayMonth(date, timeZone: timeZone)) at \(time)"
        }
    }

    /// After the last-checked time while an update is known; `(skipped)` when it is the skipped version.
    public static func availableSuffix(_ version: Version, skipped: Bool = false) -> String {
        " · \(version) available" + (skipped ? " (skipped)" : "")
    }

    /// `None` or the skipped version.
    public static func skipped(_ version: Version?) -> String {
        version.map(\.description) ?? none
    }

    // MARK: - App menu (U4)

    public static let checkForUpdates = "Check for Updates…"

    public static func updateTo(_ version: Version) -> String {
        "Update to \(version)…"
    }

    // MARK: - Manual check alerts (U4)

    public static let upToDateTitle = "You’re up to date"

    public static func upToDateMessage(_ version: Version) -> String {
        "Skillcask \(version) is the newest version."
    }

    public static let failedTitle = "Couldn’t check for updates"
    /// `latest: null`: the CLI reached the tap but its cask named no version it could read.
    public static let unknownMessage = "GitHub answered, but named no version Skillcask could read. Try again later."

    /// The CLI set in Settings › General predates `self-check` (`Capabilities.Feature.selfCheck`; the release is
    /// `Capabilities.shipped`).
    public static func unsupportedMessage(_ version: Version) -> String {
        "The command-line tool Skillcask uses (\(version)) is too old to check for updates. In Settings › General, "
            + "use the detected one or choose a newer one."
    }

    public static let tryAgain = "Try Again"
    public static let ok = "OK"

    /// The alert line of a failed check: the CLI's error sentence, then what to do when it says.
    public static func failedMessage(_ error: CLIError) -> String {
        let message = ErrorCopy.message(for: error)
        return [message.title, message.action].compactMap { $0 }.joined(separator: " ")
    }
}
