import Foundation
import SkillcaskDomain

/// The words of the detail's Versions tab (Versions and Versions-States boards): the row labels and their detail
/// sentences, the callouts of each state, the full list's header and standings, and the footnote. Dates come from
/// `Formatters`; a date no document carries reads "unknown" (Q2, Q6). Versions never carry a `v` (as `Labels`);
/// a tag name keeps its own spelling (`v4.1.0`).
///
/// Tag moved deviates from Versions-States on purpose: the board says "The tag v4.1.0 now points at different
/// content than when it was published." on the "Available in range" row, but `outdated` reports only the tag of
/// the LOCKED version, comparing the commit skills.lock recorded with the commit the tag names now (`moved_tag`,
/// `src/commands.rs` 1775–1779). So `tagMovedTitle` names the installed version's tag and "when it was locked",
/// and the `Tag moved · was …, now …` strip sits on the Installed row.
public enum VersionsCopy {
    // MARK: - Row labels

    public static let installed = "Installed"
    public static let allowedRange = "Allowed range"
    public static let availableInRange = "Available in range"
    public static let newestOverall = "Newest overall"

    // MARK: - Row details

    /// The column's word for a date no document carries (Versions board footnote).
    public static let unknown = "unknown"

    /// `Released 12 Sep 2026`, or `Release date unknown` (invented: the board only says the column reads unknown).
    public static func released(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "Release date \(unknown)" }
        return "Released \(Formatters.dayMonthYear(date, timeZone: timeZone))"
    }

    /// `Released 12 Sep 2026 · in skills.lock` (Versions board).
    public static func installedDetail(released date: Date?, timeZone: TimeZone = .current) -> String {
        released(date, timeZone: timeZone) + RowCopy.separator + "in \(DetailOverviewCopy.lockFile)"
    }

    /// `Linked into Claude Code, Cursor` (Versions board), from the scope's targets.
    public static func linkedInto(_ agents: [String]) -> String {
        "Linked into \(agents.joined(separator: ", "))"
    }

    /// `From skills.toml · up to the next major` for a caret range of a major above 0 (Versions board), else
    /// `From skills.toml` (Versions-States).
    public static func rangeDetail(_ range: String) -> String {
        let nextMajor = range.hasPrefix("^") && !range.hasPrefix("^0")
        return nextMajor ? "From skills.toml" + RowCopy.separator + "up to the next major" : "From skills.toml"
    }

    /// `Released 28 Oct 2026 · eligible 30 Oct 2026 (72 h)` (Versions board). Without a date: `eligible date
    /// unknown` (invented); without a policy row the parenthesis is left out.
    public static func cooldownDetail(
        released date: Date?, eligible: Date?, minimumAge: String?, timeZone: TimeZone = .current
    ) -> String {
        var eligibleText =
            eligible.map { "eligible \(Formatters.dayMonthYear($0, timeZone: timeZone))" } ?? "eligible date \(unknown)"
        if let minimumAge {
            eligibleText += " (\(minimumAge))"
        }
        return released(date, timeZone: timeZone) + RowCopy.separator + eligibleText
    }

    /// The trailing word of the waiting row (Versions board).
    public static let waiting = "Waiting"

    /// `Released 24 Oct 2026 · skipped 1.3.0` (Versions-States); `skipped` only when the full list is loaded.
    public static func availableDetail(released date: Date?, skipped: [String], timeZone: TimeZone = .current) -> String
    {
        guard !skipped.isEmpty else { return released(date, timeZone: timeZone) }
        return released(date, timeZone: timeZone) + RowCopy.separator + "skipped \(skipped.joined(separator: ", "))"
    }

    /// `Tag moved · was a81f2c0, now 3fd09e1` (Versions-States; the board's "on 25 Oct 2026" has no source, Q6).
    public static func tagMovedDetail(_ move: VersionsModel.TagMove) -> String {
        "Tag moved" + RowCopy.separator + "was \(shortCommit(move.from)), now \(shortCommit(move.to))"
    }

    /// The first seven characters of a commit, as the boards print it.
    public static func shortCommit(_ sha: String) -> String {
        String(sha.prefix(7))
    }

    /// `Nothing newer below 3.0` (Versions-States); `Nothing newer in your range` when the newest overall is not
    /// a plain version (invented).
    public static func nothingNewer(below major: Int?) -> String {
        guard let major else { return "Nothing newer in your range" }
        return "Nothing newer below \(major).0"
    }

    /// The newest overall is the version of the row above (Versions-States).
    public static let same = "Same"
    /// The cooldown screen's longer form (Versions board).
    public static let sameAsAbove = "Same as above; no major release outside the range"

    /// `Released 15 Oct 2026 · outside ^2.0` (Versions-States); `outside your range` without a known range
    /// (invented).
    public static func outsideDetail(released date: Date?, range: String?, timeZone: TimeZone = .current) -> String {
        released(date, timeZone: timeZone) + RowCopy.separator + (range.map { "outside \($0)" } ?? "outside your range")
    }

    // MARK: - Callouts

    /// `3.1.0 is the newest version.` (Versions-States up to date).
    public static func newestVersion(_ version: String) -> String {
        "\(version) is the newest version."
    }

    /// `Checked 4 min ago.` (Versions-States up to date).
    public static func checked(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        "Checked \(DetailOverviewCopy.checkedAgo(date, now: now, timeZone: timeZone))."
    }

    /// `4.3.0 becomes available on 30 Oct 2026.` (Versions board, which breaks the line where the strip's one
    /// paragraph needs the full stop); `4.3.0 waits for the minimum release age.` without a date (invented).
    public static func cooldownTitle(_ version: String, eligible: Date?, timeZone: TimeZone = .current) -> String {
        guard let eligible else { return "\(version) waits for the minimum release age." }
        return "\(version) becomes available on \(Formatters.dayMonthYear(eligible, timeZone: timeZone))."
    }

    /// The cooldown callout's sentences (Versions board): the policy and the release time. The not-enforced policy
    /// sentence, the unknown release sentence and the last sentence (instead of the board's "nothing to do now")
    /// are invented.
    public static func cooldownBody(
        minimumAge: ScopeSnapshot.PolicyRow?, released date: Date?, timeZone: TimeZone = .current
    ) -> String {
        var sentences: [String] = []
        if let minimumAge {
            let value = OverviewCopy.policyValue(minimumAge.value)
            let source =
                minimumAge.isEnforcedByOrganisation
                ? "set in \(minimumAge.origin) and enforced by your organisation"
                : minimumAge.isEnforced ? "set and enforced in your config.toml" : "set in \(minimumAge.origin)"
            sentences.append("Your minimum release age is \(value), \(source).")
        }
        if let date {
            sentences.append(
                "It was released \(Formatters.dayMonthYear(date, timeZone: timeZone)) at \(Formatters.time(date, timeZone: timeZone))."
            )
        } else {
            sentences.append("Its release date is \(unknown).")
        }
        // The board's "…once it is old enough; nothing to do now." overclaims: while `within` waits, `outdated`
        // prints no older eligible version, which `update` may lock now (invented).
        sentences.append(
            "Skillcask offers it once it is old enough. An older version in your range may be eligible now; "
                + "Review changes… on the Overview shows what Update would lock.")
        return sentences.joined(separator: " ")
    }

    /// `3.0.0 exists but needs a range change.` (Versions-States): text, never a button, because policy may
    /// forbid editing skills.toml here.
    public static func needsRangeChange(_ version: String) -> String {
        "\(version) exists but needs a range change."
    }

    /// The sentence after `needsRangeChange` (Versions-States); without a known caret range it says the range
    /// does not reach the version (invented).
    public static func rangeChangeBody(range: String?) -> String {
        let reach =
            if let range, range.hasPrefix("^") {
                "Your range \(range) in skills.toml stops at the next major."
            } else if let range {
                "Your range \(range) in skills.toml does not reach it."
            } else {
                "Your range in skills.toml does not reach it."
            }
        return reach + " Edit the range in the repository to allow it; the app does not change skills.toml ranges."
    }

    /// `The tag 4.0.1 of your installed version now points at different content than when it was locked.` Board
    /// wording (Versions-States, Flow-F3) adjusted to what the CLI reports: the installed version's tag (see the
    /// type's note).
    public static func tagMovedTitle(_ tag: String) -> String {
        "The tag \(tag) of your installed version now points at different content than when it was locked."
    }

    /// The cooldown callout's trailing link (Versions board), which opens the Review sheet.
    public static let readChanges = "Read the changes…"

    public static let tagMovedBody =
        "Review carefully before updating. Tags can be moved by the repository owner, or by someone who took it "
        + "over; the lock pins content, not the tag, so nothing on your disk changed."

    /// The callout before `outdated` answered for this package. Invented: no board draws it.
    public static let notCheckedTitle = OverviewCopy.updatesNotChecked + "."
    public static let notCheckedBody = "Check for updates to see what your range allows and the newest overall."

    // MARK: - Footnotes

    /// Under an update within range (Versions-States).
    public static let reviewFootnote =
        "Update goes through the Review sheet: the text diff is shown before anything changes."

    /// Under a moved tag (Versions-States), true since `DetailActions` offers only "Review changes…" then.
    public static let tagMovedFootnote =
        "Update stays available but is never the default button while this note is present."

    /// The tab's last line (Versions board).
    public static let datesFootnote =
        "Dates come from the source when it provides them; otherwise the column reads “unknown”."

    // MARK: - All known versions

    public static let allVersions = "All known versions"

    /// `All known versions · 9`; without a count (not loaded yet) the bare title.
    public static func allVersions(count: Int?) -> String {
        guard let count else { return allVersions }
        return allVersions + RowCopy.separator + "\(count)"
    }

    /// The collapsed list's link (Versions-States).
    public static let show = "Show"
    /// The expanded list's link. Invented: the boards only draw the list open.
    public static let hide = "Hide"
    public static let showAll = "Show all"

    /// `4 older versions hidden` (Versions board); the singular is invented.
    public static func hidden(_ count: Int) -> String {
        count == 1 ? "1 older version hidden" : "\(count) older versions hidden"
    }

    /// The spinner's label while `info <package>` downloads. Invented.
    public static let loading = "Loading versions…"
    /// The control that stops the download. Invented.
    public static let cancel = "Cancel"
    /// The failure line's lead before the error's sentence. Invented.
    public static let loadFailed = "Couldn’t load the versions."

    /// A version's date cell: `28 Oct 2026` or `unknown`.
    public static func date(_ date: Date?, timeZone: TimeZone = .current) -> String {
        date.map { Formatters.dayMonthYear($0, timeZone: timeZone) } ?? unknown
    }

    /// A version's standing (Versions board). `Outside your range` and `Older` are invented; `.unknown` says
    /// nothing.
    public static func standing(_ standing: VersionsModel.Standing, timeZone: TimeZone = .current) -> String {
        switch standing {
        case .outsideRange: "Outside your range"
        case .waiting(let eligible):
            eligible.map { "Too new for your policy until \(Formatters.dayMonth($0, timeZone: timeZone))" }
                ?? "Too new for your policy"
        case .available: availableInRange
        case .installed: installed
        case .inRange: "In range"
        case .belowRange: "Below your range"
        case .older: "Older"
        case .unknown: ""
        }
    }
}
