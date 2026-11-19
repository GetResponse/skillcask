import Foundation
import SkillcaskCore
import SkillcaskDomain

/// The words of the Activity drawer (S15, Activity board): its header, a row's exit word and timing, and the
/// expanded transcript the row's Copy puts on the pasteboard. The row's title is the run's own (`ActivityEntry
/// .headline`, from `ActionCopy`, `OutcomeCopy` and the sheets' Copy).
///
/// Board strings: `Activity`, `this session · 6 runs`, `Copy All`, `Copy`, `Reveal skills.lock`, `Close activity`
/// (the close button's `aria-label`), `ok`, `sign-in needed`, `3.2 s · 14:02`, and the read titles `Opened api`,
/// `Checked for updates`, `Reviewed changes for pdf 1.2.0 → 1.4.0`.
///
/// Invented: `this session · 1 run`, `this session · 250 runs · last 100 kept`,
/// `No runs yet this session.`, `Hide Activity`, `running`, the exit words `needs attention`, `refused by policy`,
/// `failed`, `network error`, `hash mismatch`, `file error`, `exit 101` (any other code), `cancelled`, `stopped`,
/// `unreadable output`, `not run`, the duration past a minute `1 min 12 s`, `No output.`,
/// `… 25 earlier lines not kept` (`1 earlier line`), `Environment from Settings: HTTPS_PROXY=••••, …`, and the read
/// titles `Refreshed api`, `Couldn’t open api.`, `Couldn’t refresh api.`, `Couldn’t check for updates.`,
/// `Reviewed changes for 2 packages`, `Reviewed changes: nothing to update`, `Reviewed changes for pdf` (no
/// version known).
public enum ActivityCopy {
    // MARK: - Header

    public static let title = ShellCopy.activity
    /// `this session · 6 runs`; past the session's bound `this session · 250 runs · last 100 kept`.
    public static func session(runs: Int, kept: Int? = nil) -> String {
        let count = "this session · \(runs) " + (runs == 1 ? "run" : "runs")
        guard let kept, kept < runs else { return count }
        return count + " · last \(kept) kept"
    }

    public static let copyAll = "Copy All"
    public static let copy = "Copy"
    /// The close button's accessibility label (the board's `aria-label`).
    public static let close = "Close activity"
    public static let showActivity = ShellCopy.showActivity
    public static let hideActivity = "Hide Activity"
    public static let revealLock = "Reveal skills.lock"
    public static let empty = "No runs yet this session."

    // MARK: - Reads (the titles of the reads the user started)

    /// `Opened api`: opening the scope read its status, audit and doctor.
    public static func opened(_ scope: String) -> String {
        "Opened \(scope)"
    }

    public static func couldNotOpen(_ scope: String) -> String {
        OutcomeCopy.couldNot("open \(scope)")
    }

    /// `Refreshed api`: ⌘R or Retry read them again.
    public static func refreshed(_ scope: String) -> String {
        "Refreshed \(scope)"
    }

    public static func couldNotRefresh(_ scope: String) -> String {
        OutcomeCopy.couldNot("refresh \(scope)")
    }

    public static let checkedForUpdates = "Checked for updates"
    public static let couldNotCheckForUpdates = OutcomeCopy.couldNot("check for updates")

    /// `Reviewed changes for pdf 1.2.0 → 1.4.0`; `Reviewed changes for pdf` when `diff` named no versions.
    public static func reviewed(_ name: String, from: String?, to: String?) -> String {
        let versions = [from, to].compactMap { $0 }.joined(separator: " → ")
        return "Reviewed changes for \(name)" + (versions.isEmpty ? "" : " \(versions)")
    }

    /// `Reviewed changes for 2 packages`; `Reviewed changes: nothing to update` for none.
    public static func reviewedAll(_ count: Int) -> String {
        count == 0 ? "Reviewed changes: nothing to update" : "Reviewed changes for \(count) packages"
    }

    // MARK: - Row

    /// The row's title: the run's headline without its closing period (`Couldn’t sync sql-review`), or, for a
    /// batch item that words none, its progressive title without the ellipsis (`Adopting pdf`).
    public static func headline(of entry: ActionRunner.ActivityEntry) -> String {
        let said = entry.headline.isEmpty ? entry.title : entry.headline
        var text = said.trimmingCharacters(in: .whitespaces)
        while let last = text.last, last == "." || last == "…" {
            text.removeLast()
        }
        return text
    }

    /// The exit word, in its severity's text colour (`ok` green, `sign-in needed` red).
    public static func word(for ending: ActionRunner.ActivityEntry.Ending) -> String {
        switch ending {
        case .ok: "ok"
        case .findings: "needs attention"
        case .refused: "refused by policy"
        case .cancelled: "cancelled"
        case .killed: "stopped"
        // Invented: the app stopped a read that did not answer within `GuardedClient.readTimeout`.
        case .timedOut: "timed out"
        case .unreadable: "unreadable output"
        case .notRun: "not run"
        case .failed(let code):
            switch code {
            case .problem: "failed"
            case .signIn: "sign-in needed"
            // Exit 3 (`src/error.rs`) is any network failure: unreachable, HTTP 5xx, a missing dist, a refused
            // plain-HTTP URL, a registry's invalid JSON, a git server error. "offline" would be false for most.
            case .network: "network error"
            case .integrity: "hash mismatch"
            case .file: "file error"
            case .other(let status): "exit \(status)"
            }
        }
    }

    /// The word's colour: green for ok, amber for an answer with findings or a policy refusal, grey for a run the
    /// user stopped or that never started, red for the rest.
    public static func severity(for ending: ActionRunner.ActivityEntry.Ending) -> Severity {
        switch ending {
        case .ok: .ok
        case .findings, .refused: .warning
        case .cancelled, .notRun: .neutral
        case .failed, .killed, .timedOut, .unreadable: .error
        }
    }

    /// The word of the run in flight, in `Color.textSecondary`.
    public static let running = "running"

    /// `3.2 s · 14:02`: how long the run took, then when it started on the Mac's clock.
    public static func timing(_ duration: Duration, startedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(self.duration(duration)) · \(clock(startedAt, timeZone: timeZone))"
    }

    /// `0:03 · 14:02`: the run in flight, elapsed as the list header counts it.
    public static func elapsed(_ seconds: TimeInterval, startedAt: Date, timeZone: TimeZone = .current) -> String {
        "\(AdoptCopy.elapsed(seconds)) · \(clock(startedAt, timeZone: timeZone))"
    }

    /// `3.2 s` under a minute, `1 min 12 s` past it.
    public static func duration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
        guard seconds >= 59.95 else { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
    }

    /// `14:02`, 24-hour, in `timeZone` (the Mac's own: a run happened now, not on a release calendar).
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        date.formatted(
            Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: timeZone)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits))
    }

    // MARK: - Transcript

    public static let noOutput = "No output."

    /// `… 25 earlier lines not kept`.
    public static func omitted(_ count: Int) -> String {
        "… \(count) earlier " + (count == 1 ? "line" : "lines") + " not kept"
    }

    /// `Environment from Settings: HTTPS_PROXY=••••, SKILLCASK_CACHE_DIR=••••`: names only, every value masked.
    public static func environment(_ names: [String]) -> String {
        "Environment from Settings: " + names.map { "\($0)=••••" }.joined(separator: ", ")
    }

    /// The lines of an expanded row above its transcript: the command (one per command of a read), then the
    /// environment it got. Only the commands (`commands(of:)`) are SF Mono.
    public static func commandLines(of entry: ActionRunner.ActivityEntry) -> [String] {
        commands(of: entry) + (entry.environmentOverrides.isEmpty ? [] : [environment(entry.environmentOverrides)])
    }

    /// The command lines of `entry`: one, or the trio of a scope read.
    public static func commands(of entry: ActionRunner.ActivityEntry) -> [String] {
        entry.command.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// The lines of the transcript box: the dropped-lines note, then every line kept; `No output.` when empty.
    public static func transcriptLines(of entry: ActionRunner.ActivityEntry) -> [String] {
        transcriptLines(entry.transcript, omitted: entry.omittedLines)
    }

    /// The transcript box of `lines` (also the run in flight).
    public static func transcriptLines(_ lines: [OutputLine], omitted: Int) -> [String] {
        let kept = lines.map(\.text)
        if kept.isEmpty && omitted == 0 {
            return [noOutput]
        }
        return (omitted > 0 ? [Self.omitted(omitted)] : []) + kept
    }

    /// What a row's Copy puts on the pasteboard: exactly the expanded row's text, top to bottom.
    public static func copyText(of entry: ActionRunner.ActivityEntry) -> String {
        (commandLines(of: entry) + transcriptLines(of: entry)).joined(separator: "\n")
    }

    /// The header line of a row as Copy All writes it: `Checked api · ok · 0.4 s · 14:02`.
    public static func summary(of entry: ActionRunner.ActivityEntry, timeZone: TimeZone = .current) -> String {
        [
            headline(of: entry), word(for: entry.ending),
            timing(entry.duration, startedAt: entry.startedAt, timeZone: timeZone),
        ]
        .joined(separator: " · ")
    }

    /// Copy All: every row, newest first, each as its header line followed by its expanded text.
    public static func copyAllText(of entries: [ActionRunner.ActivityEntry], timeZone: TimeZone = .current) -> String {
        entries.map { summary(of: $0, timeZone: timeZone) + "\n" + copyText(of: $0) }.joined(separator: "\n\n")
    }
}
