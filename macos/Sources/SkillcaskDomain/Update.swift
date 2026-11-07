import Foundation
import SkillcaskCore

/// What `outdated` knows about one package. `within` is the newest version the constraint allows and `latest` the
/// newest overall; neither applies the minimum release age (`src/commands.rs` `outdated`: `within` is
/// `registry::newest`, which ignores the cooldown). When `within` is still inside the minimum release age the CLI
/// says so in `note` (`1.1.0 eligible 2026-10-30T09:14:00Z`, the version being `within`'s spelling), and `update`
/// would not lock it: that row is a cooldown, not an update. Limit: GitHub and git sources get no such note, so
/// their cooling version still reads as `available` (see `Cooldown.version`).
public struct Update: Hashable, Sendable {
    /// A newer version inside the range that waits for the minimum release age.
    public struct Cooldown: Hashable, Sendable {
        /// The waiting version as the CLI spells it (`4.3.0`; registries may spell `v4.3.0`). Never from a GitHub or
        /// git source: `github::newest` ignores the minimum release age and `outdated` prints no cooldown note there
        /// (`src/github.rs` `newest`, `src/commands.rs` `outdated`), so such a row shows `available` even when
        /// `update` would not lock it yet; the Review sheet says so when `diff` finds nothing (`ReviewStore`).
        public let version: String
        /// When it becomes eligible; nil when neither the note nor the planned `eligible` key names a date.
        public let eligible: Date?
    }

    public let package: String
    public let locked: String?
    public let within: String?
    public let latest: String?
    /// When the cooldown on a newer version ends, from the planned `eligible` key or the `note` text.
    public let eligible: Date?
    /// When `latest` was published, from the planned `released` key; nil until the CLI prints it.
    public let released: Date?
    public let note: String?

    public init(_ row: OutdatedDocument.Package) {
        self.init(
            package: row.package, locked: row.locked, within: row.within, latest: row.latest,
            eligible: row.eligible.flatMap(Self.date) ?? row.note.flatMap(Self.eligibleDate),
            released: row.released.flatMap(Self.date), note: row.note)
    }

    private init(
        package: String, locked: String?, within: String?, latest: String?, eligible: Date?, released: Date?,
        note: String?
    ) {
        self.package = package
        self.locked = locked
        self.within = within
        self.latest = latest
        self.eligible = eligible
        self.released = released
        self.note = note
    }

    /// The newer version that waits for the minimum release age: the one the note names (`<version> eligible
    /// <date>`), or `within` when only the planned `eligible` key is present; nil when that version is the
    /// locked one (nothing newer waits) or nothing waits.
    public var cooldown: Cooldown? {
        // A date without a noted version can only come from the planned `eligible` key, which dates `within`.
        guard let waiting = note.flatMap(Self.notedVersion) ?? (eligible != nil ? within : nil),
            !Self.same(waiting, locked)
        else { return nil }
        return Cooldown(version: waiting, eligible: eligible)
    }

    /// A newer version inside the constraint that `update` would lock; nil when the lock is current, the package
    /// is not locked yet, or `within` still waits for the minimum release age.
    public var available: (from: String, to: String)? {
        guard let locked, let within, !Self.same(within, locked) else { return nil }
        if let cooldown, Self.same(cooldown.version, within) {
            return nil
        }
        return (locked, within)
    }

    /// A newer version that only a constraint change would reach.
    public var outsideRange: String? {
        guard let latest, latest != within else { return nil }
        return latest
    }

    /// This update after a fresh `status` showed `installed` for the package: when that is the version `outdated`
    /// offered (`within`), the update has been applied and the row is current without waiting for the next
    /// network check. Any other version leaves the update as `outdated` printed it.
    public func settled(installed: String?) -> Update {
        guard let installed, let within, Self.same(installed, within), !Self.same(locked, within) else { return self }
        return Update(
            package: package, locked: installed, within: within, latest: latest, eligible: eligible,
            released: released, note: note)
    }

    // MARK: - Parsing

    static func date(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }

    /// The date of `4.3.0 eligible 2026-10-26T21:44:27Z`.
    public static func eligibleDate(_ note: String) -> Date? {
        guard let parts = split(note) else { return nil }
        return date(parts.date)
    }

    /// The version of `4.3.0 eligible 2026-10-26T21:44:27Z`, as spelled; nil for any other note (a moved tag).
    public static func notedVersion(_ note: String) -> String? {
        split(note)?.version
    }

    /// `<version> eligible <date>`, the one shape `outdated` prints for a cooldown (`src/commands.rs` `outdated`):
    /// one word before ` eligible `, one word after it.
    private static func split(_ note: String) -> (version: String, date: String)? {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: " eligible ") else { return nil }
        let version = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let date = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !version.isEmpty, !date.isEmpty, !version.contains(" "), !date.contains(" ") else { return nil }
        return (version, date)
    }

    /// Two spellings of one version: equal once a leading `v` is dropped (`v4.3.0` and `4.3.0`).
    static func same(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return left == right }
        return bare(left) == bare(right)
    }

    /// `4.3.0` of `v4.3.0`.
    public static func bare(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }
}
