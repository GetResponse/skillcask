import Foundation
import SkillcaskCore

/// What the detail's Versions tab knows about one locked package (S6): the installed version, the newest the
/// allowed range reaches, the newest overall, their release dates when a document carries them, and the one state
/// the tab explains (up to date, update within range, cooldown, major outside the range, tag moved). Pure: built
/// from the `SkillEntry`, its `Update`, the scope's policy rows and the allowed range; the full version list comes
/// later from a network `info <package>` and is classified by `listed(_:)`.
///
/// Release dates (D67, Q2), first source that dates the version wins:
/// - newest overall: `outdated`'s `latest-released`, `info`'s `versions-released` map, an earlier plan's `released`;
/// - installed: `status`'s `released` (skills.lock), `locked-released` when it is the locked version, the map, then
///   the old `released` when it is `latest`;
/// - in range: `within-released`, the map; a cooldown's version: `within-released` when it is `within`, the map, the
///   old `released` when it is `latest`;
/// - a row of the full list: the named row it is (newest, installed, in range), else the map.
/// Composer dates every version; GitHub and git only the locked tag; a CLI before D67 prints none of these keys. A
/// version no source dates has a nil date and the view says "unknown" (Q6).
public struct VersionsModel: Hashable, Sendable {
    /// `tag 4.0.1 moved from a81f2c0d4e9b to 3fd09e1c7a52`: the CLI's free-text note on a GitHub tag source whose
    /// LOCKED version's tag now points at another commit than skills.lock recorded (Q3; `moved_tag`,
    /// src/commands.rs 1775–1779). Matched on the `tag ` prefix and the ` moved from ` / ` to ` words.
    public struct TagMove: Hashable, Sendable {
        public let tag: String
        /// The commit the lock recorded for the tag.
        public let from: String
        /// The commit the tag points at now.
        public let to: String

        public init(tag: String, from: String, to: String) {
            self.tag = tag
            self.from = from
            self.to = to
        }

        /// The move a note describes; nil for any other note.
        public init?(note: String) {
            let text = note.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("tag "), let moved = text.range(of: " moved from "),
                let to = text.range(of: " to ", range: moved.upperBound..<text.endIndex)
            else { return nil }
            let tag = text[text.index(text.startIndex, offsetBy: 4)..<moved.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let from = text[moved.upperBound..<to.lowerBound].trimmingCharacters(in: .whitespaces)
            let target = text[to.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !tag.isEmpty, !from.isEmpty, !target.isEmpty, !from.contains(" ") else { return nil }
            self.init(tag: tag, from: from, to: target)
        }
    }

    /// A newer version that waits for the policy's minimum release age.
    public struct Cooldown: Hashable, Sendable {
        /// The waiting version, from the note (`4.3.0 eligible …`); never with a leading `v`.
        public let version: String
        /// When it becomes eligible; nil when neither `eligible` nor the note names a date.
        public let eligible: Date?
        /// When it was published: `within-released` (the waiting version is `within`), else the `versions-released`
        /// map, else the old `released` key when it is `latest`; nil when none dates it.
        public let released: Date?
    }

    /// The one state the tab's callout explains, worst-explained first.
    public enum Status: Hashable, Sendable {
        /// `outdated` has not answered for this package (not checked yet, or offline).
        case unchecked
        /// The tag of the version in range points at other content than when it was locked.
        case tagMoved(TagMove)
        /// A newer version inside the range; `Update` reaches it.
        case available(String)
        /// A newer version waits for the minimum release age.
        case cooldown(Cooldown)
        /// A newer version exists only outside the range: a range change in skills.toml would reach it.
        case outsideRange(String)
        case upToDate
    }

    /// Where one entry of the full version list stands relative to the lock, the range and the policy.
    public enum Standing: Hashable, Sendable {
        /// Newer than anything the range reaches.
        case outsideRange
        /// The cooldown's version, eligible on the date.
        case waiting(eligible: Date?)
        /// The newest in range, which `Update` would lock.
        case available
        case installed
        /// Between the installed version and the newest in range, or older than installed and inside a caret range.
        case inRange
        /// Older than installed and below the caret range.
        case belowRange
        /// Older than installed, the range unknown or not a caret range.
        case older
        /// Not a `major.minor.patch` version: nothing is claimed.
        case unknown
    }

    /// One row of the full version list.
    public struct Listed: Hashable, Sendable, Identifiable {
        public let version: String
        public let released: Date?
        public let standing: Standing

        public var id: String { version }
    }

    public let package: String?
    /// `status.version`, else the lock's version from `outdated`.
    public let installed: String?
    public let installedReleased: Date?
    /// The constraint in skills.toml (`^4.2`), when `info` named it.
    public let allowedRange: String?
    /// `outdated.within`: the newest version the range allows, the minimum release age not applied; `update` locks
    /// it unless it still waits (`cooldown`).
    public let within: String?
    /// When `within` was published: `within-released`, else the `versions-released` map; nil when neither dates it.
    public let withinReleased: Date?
    public let latest: String?
    public let latestReleased: Date?
    /// The `min-release-age` policy row, nil when unset or zero (`0`; `0h` before 0.12.1).
    public let minimumAge: ScopeSnapshot.PolicyRow?
    public let status: Status
    /// The waiting version; also set when the status is `available` and a newer version still cools down.
    public let cooldown: Cooldown?
    public let tagMove: TagMove?
    /// `info`'s `versions-released`, keyed by `Update.bare` so `v4.3.0` and `4.3.0` find one date.
    private let releasedByVersion: [String: Date]

    /// `released` is the package `info`'s `versions-released` (`InfoDocument.versionsReleased`, parsed), empty until
    /// that document is loaded or from a CLI before D67.
    public init(
        entry: SkillEntry, policy: [ScopeSnapshot.PolicyRow], allowedRange: String?, released: [String: Date] = [:]
    ) {
        let update = entry.update
        let map = Dictionary(released.map { (Update.bare($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        let dated = { (version: String?) in version.flatMap { map[Update.bare($0)] } }
        releasedByVersion = map
        package = entry.package
        let installed = entry.version ?? update?.locked
        self.installed = installed
        self.allowedRange = allowedRange
        within = update?.within
        latest = update?.latest
        withinReleased = update?.withinReleased ?? dated(update?.within)
        latestReleased = update?.latestReleased ?? dated(update?.latest) ?? update?.released
        installedReleased =
            entry.released
            ?? (installed != nil && Update.same(installed, update?.locked) ? update?.lockedReleased : nil)
            ?? dated(installed) ?? (installed != nil && installed == update?.latest ? update?.released : nil)
        minimumAge = policy.first { $0.kind == .minReleaseAge && !ScopeSnapshot.PolicyRow.isZeroAge($0.value) }
        tagMove = update?.note.flatMap(TagMove.init(note:))
        cooldown = update.flatMap { Self.cooldown($0, dated: dated) }
        status = Self.status(update: update, tagMove: tagMove, cooldown: cooldown)
    }

    /// `info`'s `versions-released` as dates for `init(…, released:)`; a value that is not RFC 3339 is left out.
    public static func released(in info: InfoDocument?) -> [String: Date] {
        (info?.versionsReleased ?? [:]).compactMapValues(Update.date)
    }

    // MARK: - Derived

    /// The version the "in range" row shows: the waiting version during a cooldown, else `within`.
    public var inRangeVersion: String? {
        if case .cooldown(let cooldown) = status {
            return cooldown.version
        }
        return within
    }

    /// When the version of the "in range" row was published, when known.
    public var inRangeReleased: Date? {
        if case .cooldown(let cooldown) = status {
            return cooldown.released
        }
        return withinReleased ?? released(within)
    }

    /// Whether the newest version overall is the one the "in range" row shows.
    public var latestIsInRange: Bool {
        latest != nil && Update.same(latest, inRangeVersion)
    }

    /// The "in range" row is drawn unless the lock already is the newest of everything.
    public var showsInRangeRow: Bool {
        switch status {
        case .unchecked, .upToDate: false
        case .tagMoved, .available, .cooldown, .outsideRange: true
        }
    }

    /// The major version the range stops below (`3` for latest `3.0.0`): "Nothing newer below 3.0".
    public var nextMajor: Int? {
        guard let latest, let version = Version(latest) else { return nil }
        return version.major
    }

    /// Versions strictly between the installed one and `within`, in `versions`' order: "skipped 1.3.0".
    public func skipped(in versions: [String]) -> [String] {
        guard let low = installed.flatMap(Self.parse), let high = within.flatMap(Self.parse) else { return [] }
        return versions.filter { text in
            guard let version = Version(text) else { return false }
            return low < version && version < high
        }
    }

    /// The full list (`info.versions`, newest first as the CLI prints it), each with its standing and the release
    /// date when a document carries it.
    public func listed(_ versions: [String]) -> [Listed] {
        versions.map { Listed(version: $0, released: released($0), standing: standing(of: $0)) }
    }

    // MARK: - Classification

    /// The date of the named row the version is (newest, installed, in range), so the list agrees with the rows
    /// above it, else the `versions-released` map. A named row without a date does not stop the lookup.
    private func released(_ version: String?) -> Date? {
        guard let version else { return nil }
        return (Update.same(version, latest) ? latestReleased : nil)
            ?? (Update.same(version, installed) ? installedReleased : nil)
            ?? (Update.same(version, within) ? withinReleased : nil)
            ?? releasedByVersion[Update.bare(version)]
    }

    private func standing(of text: String) -> Standing {
        if text == installed {
            return .installed
        }
        // `cooldown.version` is bare; a registry may list `v4.3.0`.
        if let cooldown, Update.same(text, cooldown.version) {
            return .waiting(eligible: cooldown.eligible)
        }
        if text == within, within != installed {
            return .available
        }
        guard let version = Version(text) else { return .unknown }
        let top = within.flatMap(Self.parse)
        if let top, top < version {
            return .outsideRange
        }
        if let current = installed.flatMap(Self.parse), current < version {
            return .inRange
        }
        guard let bounds = allowedRange.flatMap(Self.caretBounds) else { return .older }
        return bounds.contains(version) ? .inRange : .belowRange
    }

    /// `Version(_:)` by name: `Version` has two failable string initialisers.
    private static func parse(_ text: String) -> Version? {
        Version(text)
    }

    /// `^4.2` → 4.2.0 ..< 5.0.0, `^0.4` → 0.4.0 ..< 0.5.0, `^0.0.3` → 0.0.3 ..< 0.0.4 (Composer's caret); nil for
    /// any other constraint.
    static func caretBounds(_ range: String) -> Range<Version>? {
        let text = range.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("^") else { return nil }
        let parts = text.dropFirst().split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        let major = numbers[0]
        let minor = numbers.count > 1 ? numbers[1] : 0
        let patch = numbers.count > 2 ? numbers[2] : 0
        let lower = Version(major, minor, patch)
        let upper: Version
        if major > 0 || numbers.count == 1 {
            upper = Version(major + 1, 0, 0)
        } else if minor > 0 || numbers.count == 2 {
            upper = Version(0, minor + 1, 0)
        } else {
            upper = Version(0, 0, patch + 1)
        }
        return lower..<upper
    }

    /// The waiting version of `update` (`Update.cooldown`: the note's version, which the CLI takes from `within`),
    /// without a leading `v`; nil when nothing newer than the lock waits. Dated by `within-released` when it is
    /// `within`, else by the `versions-released` map (`dated`), else by the old `released` key when it is `latest`.
    private static func cooldown(_ update: Update, dated: (String?) -> Date?) -> Cooldown? {
        guard let waiting = update.cooldown else { return nil }
        let version = Update.bare(waiting.version)
        let released =
            (Update.same(version, update.within) ? update.withinReleased : nil) ?? dated(version)
            ?? (update.latest.map(Update.bare) == version ? update.released : nil)
        return Cooldown(version: version, eligible: waiting.eligible, released: released)
    }

    private static func status(update: Update?, tagMove: TagMove?, cooldown: Cooldown?) -> Status {
        guard let update else { return .unchecked }
        if let tagMove {
            return .tagMoved(tagMove)
        }
        if let (_, to) = update.available {
            return .available(to)
        }
        if let cooldown {
            return .cooldown(cooldown)
        }
        if let outside = update.outsideRange {
            return .outsideRange(outside)
        }
        return .upToDate
    }
}
