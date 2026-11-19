import Foundation

/// The words of the S4 Contents tab (Contents, Contents-States): the file line above the text, the toolbar and the
/// accessibility names of the rendered body. The warning strip's sentence is `StripCopy.invisibleCharacters`; the
/// too large and unreadable states are `EmptyCopy`. Views never spell these themselves.
public enum ContentsCopy {
    // MARK: - Toolbar (Contents, Contents-States)

    /// Opens SKILL.md in the default app for `.md`.
    public static let openInEditor = EmptyCopy.openInEditor
    public static let quickLook = "Quick Look"
    public static let copyPath = "Copy path"

    // MARK: - File line

    /// `SKILL.md · 1.8 KB · changed 3 Oct 2026`; `SKILL.md · 6.2 KB` when the date is unknown, `SKILL.md` when
    /// nothing is (an unreadable file).
    public static func fileLine(name: String, bytes: Int?, modified: Date?, timeZone: TimeZone = .current) -> String {
        var parts = [name]
        if let bytes {
            parts.append(size(bytes))
        }
        if let modified {
            parts.append(changed(modified, timeZone: timeZone))
        }
        return parts.joined(separator: " · ")
    }

    /// `changed 3 Oct 2026`.
    public static func changed(_ date: Date, timeZone: TimeZone = .current) -> String {
        "changed " + Formatters.dayMonthYear(date, timeZone: timeZone)
    }

    /// `1.8 KB`, `6.2 KB`, `48 KB`, `1.3 MB`: binary units with one decimal below ten (the boards' `1.8 KB`,
    /// `6.2 KB`, `1.3 MB`), whole numbers from ten up, no locale so the separator is always a point. Under one
    /// kilobyte `512 bytes` (no board draws it; this file's wording).
    public static func size(_ bytes: Int) -> String {
        let kib = 1024.0
        let value = Double(max(bytes, 0))
        guard value >= kib else { return bytes == 1 ? "1 byte" : "\(max(bytes, 0)) bytes" }
        let (amount, unit) = value >= kib * kib ? (value / (kib * kib), "MB") : (value / kib, "KB")
        return amount < 10 ? String(format: "%.1f %@", amount, unit) : "\(Int(amount.rounded())) \(unit)"
    }

    // MARK: - Front matter

    /// The front-matter keys whose values the boards set in mono (`name`, `allowed-tools`, `version`): names a
    /// reader meets verbatim in the repository. `description`, `license` and unknown keys stay in text.
    public static let monoKeys: Set<String> = ["name", "allowed-tools", "version"]

    /// What assistive technology hears for the front-matter card (no board source).
    public static let frontMatter = "Front matter"

    // MARK: - Unreadable (Contents-States)

    /// The accent link under Open folder and Check: discloses why the file could not be read.
    public static let details = "Details"
    /// The same link once the reason shows (no board source).
    public static let hideDetails = "Hide details"

    /// What Details discloses when SKILL.md cannot be read: the error's description, home as `~`. No path line:
    /// the empty state shows the file's path right above. A Cocoa error's description already folds in its failure
    /// reason (`The file “SKILL.md” couldn’t be opened because there is no such file.`), so the reason is added only
    /// for other domains, and only when the description does not already contain it. No board source.
    public static func readError(_ error: any Error, home: String = NSHomeDirectory()) -> String {
        let error = error as NSError
        var text = error.localizedDescription
        if error.domain != NSCocoaErrorDomain, let reason = error.localizedFailureReason, !reason.isEmpty,
            !text.contains(reason)
        {
            text += " " + reason
        }
        return abbreviatingHome(text, home: home)
    }

    /// `text` with every occurrence of the home directory written `~`.
    static func abbreviatingHome(_ text: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home + "/", with: "~/")
    }
}
