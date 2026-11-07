import Foundation
import SkillcaskDomain

/// The English of the status vocabulary (the Tokens board's status table): what a `Health`, a
/// `Severity` and a `SkillEntry.Kind` are called on screen. Views never spell these words themselves.
public enum Labels {
    // MARK: - Health

    /// The label beside the status dot for one row or detail header, worst thing first as `Health` orders it.
    public static func health(_ health: Health, timeZone: TimeZone = .current) -> String {
        switch health {
        case .installed: return "Installed"
        case .projectSkill: return "Project skill"
        case .localSkill: return "Local skill"
        case .updateAvailable(let from, let to): return "\(update) \(versionTransition(from: from, to: to))"
        case .notManaged: return "Not managed"
        case .notLinked: return "Not linked to agents"
        case .findings(let count): return findings(count)
        case .cooldown(let note): return cooldown(note: note, timeZone: timeZone)
        case .notInstalled: return "Not installed"
        case .changedOnDisk: return "Changed on disk"
        case .needsSync: return "Needs sync"
        case .duplicate: return duplicatePlaceholder
        case .unknown(let text): return cliState(text)
        }
    }

    /// The first word of an update label; the detail shows the full form, a row only `→ 1.4.0`.
    public static let update = "Update"

    /// `1.2.0 → 1.4.0`: the arrow is text, not a symbol, so it copies.
    public static func versionTransition(from: String, to: String) -> String {
        "\(from) → \(to)"
    }

    /// `1 finding`, `2 findings`.
    public static func findings(_ count: Int) -> String {
        count == 1 ? "1 finding" : "\(count) findings"
    }

    /// `4.3.0 on 30 Oct` from the CLI note `4.3.0 eligible 2026-10-30T09:14:00Z` (the board's wording, the day
    /// in `timeZone`); `Cooldown` when the note is missing or says something else. Versions never carry a `v`.
    public static func cooldown(note: String?, timeZone: TimeZone = .current) -> String {
        guard let note, let version = Update.notedVersion(note), let date = Update.eligibleDate(note) else {
            return cooldownPlaceholder
        }
        return "\(Update.bare(version)) on \(Formatters.dayMonth(date, timeZone: timeZone))"
    }

    /// Placeholder words for the two cases no board labels: a cooldown whose note names no eligible date, and a
    /// skill provided by two packages.
    static let cooldownPlaceholder = "Cooldown"
    static let duplicatePlaceholder = "Duplicate"

    /// The neutral label of a dependency row: `Required by caveman`.
    public static func requiredBy(_ packages: [String]) -> String {
        "Required by \(packages.joined(separator: ", "))"
    }

    /// A state word this app does not know: the board's wording when it has one, else the CLI text with its first
    /// letter capitalised, so a newer CLI reads as English rather than crashing an older app. Never empty: a blank
    /// state reads `Unknown`.
    static func cliState(_ text: String) -> String {
        if let known = boardWords[text] {
            return known
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return unknown }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }

    /// CLI state words the boards label explicitly (Components, Main, Tokens).
    private static let boardWords = [
        "blocked by policy": "Blocked by policy",
        "abandoned": "Abandoned",
        "tag moved": "Tag moved",
    ]

    // MARK: - Severity

    /// The name of a severity on its own, for accessibility and the sort menu ("State, worst first").
    public static func severity(_ severity: Severity) -> String {
        switch severity {
        case .neutral: "Neutral"
        case .ok: "OK"
        case .update: "Update"
        case .warning: "Warning"
        case .error: "Error"
        }
    }

    // MARK: - Kind

    /// The kind pill of a row: what the entry is, not how it is doing.
    public static func kind(_ kind: SkillEntry.Kind) -> String {
        switch kind {
        case .package, .packageOnly: "Package"
        case .dependency: "Dependency"
        case .project: "Project skill"
        case .handWritten: "Local skill"
        case .notManaged: "Not managed"
        }
    }

    // MARK: - View modes

    /// A project whose `skills.toml` does not exist yet (sidebar subtitle, Overview-States); drawn with the dashed dot.
    public static let notSetUp = "Not set up"

    /// A status that has not been read yet (the Components board's dashed example).
    public static let unknown = "Unknown"

    // MARK: - Badges

    /// What VoiceOver reads for the sidebar attention badge: `3 need attention`, `1 needs attention`.
    public static func badgeAttention(_ count: Int) -> String {
        count == 1 ? "1 needs attention" : "\(count) need attention"
    }

    /// What VoiceOver reads for the blue update badge: `2 updates`, `1 update`.
    public static func badgeUpdates(_ count: Int) -> String {
        count == 1 ? "1 update" : "\(count) updates"
    }
}
