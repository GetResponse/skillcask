import SkillcaskCore

/// The words of the one-line message strips (`MessageStrip`): the offline line in the list header (List-States),
/// the not-managed banner on first launch (Components, Overview-States), the invisible-character warning above a
/// file (Contents), and the abandoned and offline lines of the Overview tab (Detail-States). Views never spell
/// these themselves.
public enum StripCopy {
    // MARK: - S2 list header (List-States "Updates unavailable (offline)")

    /// The info strip under the list header while offline.
    public static let offlineHeader = "Offline: updates can’t be checked. Lock status is current."

    // MARK: - Components "Progress block, toast, banners"

    /// The bold lead of the Components board's info strip.
    public static let offlineTitle = "Offline."
    /// The sentence after `offlineTitle` on the Components board.
    public static let offlineBody = "Updates and details need a network connection; what the lock knows is shown."

    // MARK: - S1 Overview header: a refresh that read status but not audit or doctor

    /// The warning under the Overview's counts when `audit` or `doctor` failed while `status` answered
    /// (`ScopeStore.partialFailure`). Invented (no board draws it). One sentence per failed read: `Security findings
    /// are from an earlier check: audit failed.` while the previous document stands in, `Security findings are
    /// missing: audit failed.` when there was none; `Health …` for `doctor`.
    public static func partialRefresh(_ failure: ScopeStore.PartialFailure) -> String {
        failure.failed
            .map { read in
                let what = read == .audit ? "Security findings" : "Health"
                let command = read == .audit ? "audit" : "doctor"
                return failure.kept.contains(read)
                    ? "\(what) \(read == .audit ? "are" : "is") from an earlier check: \(command) failed."
                    : "\(what) \(read == .audit ? "are" : "is") missing: \(command) failed."
            }
            .joined(separator: " ")
    }

    /// The same strip when the whole refresh failed and the last snapshot stays (`ScopeStore.refreshError`).
    /// Invented.
    public static let refreshFailed = "Couldn’t refresh: this is what the last refresh read."
    /// The same strip when `outdated` failed other than offline (`ScopeStore.checkError`). Invented.
    public static let checkFailed = "Couldn’t check for updates: updates are from the last check."

    /// The partial-refresh strip's link once its details show. Invented (its other state is `OutcomeCopy.details`).
    public static let hideDetails = "Hide details"

    // MARK: - S1 not managed (Components, Overview-States)

    /// `12 skills on this Mac are not managed yet.`: the bold lead of the amber banner. The boards only draw a
    /// plural count; one skill reads `1 skill on this Mac is not managed yet.`
    public static func notManagedTitle(count: Int) -> String {
        count == 1
            ? "1 skill on this Mac is not managed yet."
            : "\(count) skills on this Mac are not managed yet."
    }

    /// The sentence after `notManagedTitle(count:)`; `them` becomes `it` for one skill.
    public static func notManagedBody(count: Int) -> String {
        count == 1
            ? "Adopt it to get updates and security checks."
            : "Adopt them to get updates and security checks."
    }

    /// The banner's button: applies the Not managed chip and selects its first row (Flow-F1 step 3), where each
    /// row offers Adopt….
    public static let review = "Review"

    // MARK: - S4 Contents

    /// The escaped right-to-left override the warning names, drawn in mono.
    public static let escapedOverride = "‹U+202E›"
    /// The warning strip above a file with invisible-character findings (Contents).
    public static let invisibleCharacters =
        "This file contains invisible or direction-changing characters; they are shown escaped as "
        + escapedOverride + ". An agent reads them; you would not."
    /// The strip's trailing link to the Security tab (Contents).
    public static let seeSecurity = "See Security"

    // MARK: - S3 Overview tab (Detail-States)

    /// `This package is abandoned. Use acme/lint2 instead.`; without a replacement only the first sentence.
    public static func abandoned(replacement: String?) -> String {
        guard let replacement, !replacement.isEmpty else { return "This package is abandoned." }
        return "This package is abandoned. Use \(replacement) instead."
    }

    /// The abandoned strip's sentence for `info.abandoned`; nil when the package is maintained.
    public static func abandoned(_ abandoned: InfoDocument.Abandoned?) -> String? {
        switch abandoned {
        case nil: nil
        case .withoutReplacement: Self.abandoned(replacement: nil)
        case .replacedBy(let name): Self.abandoned(replacement: name)
        }
    }

    /// `Add acme/lint2…`: the abandoned strip's button; no button without a replacement.
    public static func addReplacement(_ replacement: String) -> String {
        "Add \(replacement)…"
    }

    /// The Overview tab's info strip while offline; its button is `OutcomeCopy.retry`.
    public static let detailsOffline =
        "Details need a network connection. Description, license, versions and dependencies will load when you "
        + "are back online."
}
