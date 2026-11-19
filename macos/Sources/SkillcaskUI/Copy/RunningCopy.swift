import Foundation
import SkillcaskDomain

/// The words of a window run in the list header (S11, Running board "Short run") and of the Health results popover
/// (S12, Health-States). Run titles, toasts and banners stay in `ActionCopy`, `OutcomeCopy` and `ErrorCopy`.
///
/// Board strings: `Cancel`, `Hide output`, `0:03`, `Health · …`, `Checked 4 min ago`, `Repaired just now`,
/// `Problems · Repair or Sync fixes these`, `Problems · Sync fixes this`, `Warnings · decide yourself`,
/// `Repaired · 2`, `6 checks passed`, `Repair relinks it.`, `Sync installs it. Repair does not download.`,
/// the footnotes (`The remaining item needs a download.` the singular), `Check Again`,
/// `Health check results` (the popover's `aria-label`).
///
/// Invented: `Show output` (already `AddSkillCopy`'s), `Problems · Repair fixes
/// this`, `Problems · Repair fixes these`, `Problems · Sync fixes these`, `Problems · Repair or Sync fixes this`,
/// `Problems` (no remedy), `Repaired 4 min ago` (the minutes form), `The remaining items need a download.`,
/// `Sync puts the locked copy back. Repair does not download.`, `Repair fixes it.`, `Repair rewrites the block.`
/// (the board's "Repair adds the line." is not what `write_block` does: it rewrites the whole managed block),
/// `Sync installs the skill and links it. Repair does not download.`,
/// `Move it away, then Check Again.`.
public enum RunningCopy {
    // MARK: - Long run (Running board "Short run": spinner, title, elapsed, Cancel, bar, output)

    public static let cancel = SheetCopy.cancel
    public static let hideOutput = AddSkillCopy.hideOutput
    public static let showOutput = AddSkillCopy.showOutput

    // MARK: - Health popover (Health-States)

    /// The popover's accessibility label (the board's `aria-label`).
    public static let popoverLabel = "Health check results"

    /// `Health · 2 problems, 1 warning`, `Health · all good`.
    public static func title(problems: Int, warnings: Int) -> String {
        "\(OverviewCopy.health) · " + OverviewCopy.healthStatus(problems: problems, warnings: warnings)
    }

    /// `Checked 4 min ago`, or `Repaired just now` when the last doctor run repaired something.
    public static func when(_ date: Date, repaired: Bool, now: Date = .now) -> String {
        let checked = OverviewCopy.checked(date, now: now)
        guard repaired else { return checked }
        return "Repaired" + checked.dropFirst("Checked".count)
    }

    /// `Repaired · 2`.
    public static func repairedGroup(_ count: Int) -> String {
        "Repaired · \(count)"
    }

    /// `Problems · Repair or Sync fixes these`, `Problems · Sync fixes this`; `Problems` when neither fixes them.
    public static func problemsGroup(_ remedies: Set<DoctorItem.Remedy>, count: Int) -> String {
        let one = count == 1
        let who: String
        switch (remedies.contains(.repair), remedies.contains(.sync)) {
        case (true, true): who = "Repair or Sync"
        case (true, false): who = "Repair"
        case (false, true): who = "Sync"
        case (false, false): return "Problems"
        }
        return "Problems · \(who) fixes " + (one ? "this" : "these")
    }

    public static let warningsGroup = "Warnings · decide yourself"

    /// The quiet second line of an item that says what fixes it (Health-States): drawn when the group's label does
    /// not already name the one command that fixes every item of the group. `remedy` is the item's in its doctor
    /// answer (`ScopeSnapshot.Doctor.remedy(of:)`): a link to a skill that is not installed is Sync's.
    public static func remedyHint(_ item: DoctorItem, remedy: DoctorItem.Remedy?) -> String? {
        switch item {
        case .link(_, let problem):
            if problem == .foreign { return "Move it away, then Check Again." }
            return remedy == .sync
                ? "Sync installs the skill and links it. Repair does not download." : "Repair relinks it."
        case .notOurs:
            return "Move it away, then Check Again."
        case .staleBlock:
            return "Repair rewrites the block."
        case .strayLinks, .committed:
            return "Repair fixes it."
        case .notInstalled:
            return "Sync installs it. Repair does not download."
        case .modified:
            return "Sync puts the locked copy back. Repair does not download."
        default:
            return nil
        }
    }

    // MARK: - Footer

    /// Health-States "Problems and warnings": what Repair can and cannot do.
    public static let repairFootnote = "Repair fixes links, the git index and .gitignore. It downloads nothing."
    /// Health-States "All passed".
    public static let allPassedFootnote = "Nothing to repair. Check runs again when the project opens or on ⌘R."
    public static let checkAgain = "Check Again"

    /// Health-States "After Repair": `The remaining item needs a download.` once Repair has nothing left to do.
    public static func remainingFootnote(_ count: Int) -> String {
        count == 1 ? "The remaining item needs a download." : "The remaining items need a download."
    }
}
