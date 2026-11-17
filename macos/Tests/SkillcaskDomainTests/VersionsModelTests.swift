import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskDomain

/// The Versions tab's facts (S6) from one `status` entry and one `outdated` row: the state, the cooldown, the tag
/// move parsed from the note (Q3), the release dates (Q2) and the full list's standings.
@Suite struct VersionsModelTests {
    /// One skill `s` of package `acme/s` at `version`, with the `outdated` row `row` (JSON object) when given,
    /// `statusReleased` as the status entry's `released` and `released` as `info`'s `versions-released`.
    static func model(
        version: String = "1.2.0", row: String?, minAge: String = "72h", range: String? = "^1.2",
        statusReleased: String? = nil, released: [String: String] = [:]
    ) throws -> VersionsModel {
        let releasedKey = statusReleased.map { #","released":"\#($0)""# } ?? ""
        let status = #"""
            {"ok":true,"entries":[{"package":"acme/s","skill":"s","version":"\#(version)","state":"ok","ok":true\#(releasedKey)}],\#
            "policy":{"min-release-age":{"value":"\#(minAge)","from":"config.toml, enforced"}},"repositories":[]}
            """#
        let decoder = JSONDecoder()
        let outdated = try row.map {
            try decoder.decode(OutdatedDocument.self, from: Data(#"{"behind":[],"packages":[\#($0)]}"#.utf8))
        }
        let snapshot = ScopeSnapshot(
            status: try decoder.decode(StatusDocument.self, from: Data(status.utf8)), audit: nil, doctor: nil,
            outdated: outdated)
        let entry = try #require(snapshot.entries.first)
        return VersionsModel(
            entry: entry, policy: snapshot.policy, allowedRange: range,
            released: released.compactMapValues { try? Self.date($0) })
    }

    static func row(locked: String, within: String, latest: String, note: String? = nil, extra: String = "") -> String {
        let noteJSON = note.map { "\"\($0)\"" } ?? "null"
        return
            #"{"package":"acme/s","locked":"\#(locked)","within":"\#(within)","latest":"\#(latest)","note":\#(noteJSON)\#(extra)}"#
    }

    static func date(_ text: String) throws -> Date {
        try Date(text, strategy: .iso8601)
    }

    // MARK: - Status

    @Test func notCheckedWithoutAnOutdatedRow() throws {
        let model = try Self.model(row: nil)
        #expect(model.status == .unchecked)
        #expect(model.installed == "1.2.0")
        #expect(!model.showsInRangeRow)
    }

    @Test func upToDateDatesTheInstalledVersionWhenItIsTheLatest() throws {
        let model = try Self.model(
            row: Self.row(
                locked: "1.2.0", within: "1.2.0", latest: "1.2.0", extra: #","released":"2026-10-01T00:00:00Z""#))
        #expect(model.status == .upToDate)
        #expect(model.installedReleased == (try Self.date("2026-10-01T00:00:00Z")))
        #expect(!model.showsInRangeRow)
    }

    @Test func availableWithinTheRange() throws {
        let model = try Self.model(
            row: Self.row(
                locked: "1.2.0", within: "1.4.0", latest: "1.4.0", extra: #","released":"2026-10-24T00:00:00Z""#))
        #expect(model.status == .available("1.4.0"))
        #expect(model.inRangeVersion == "1.4.0")
        #expect(model.inRangeReleased == (try Self.date("2026-10-24T00:00:00Z")))
        #expect(model.installedReleased == nil)
        #expect(model.latestIsInRange)
        #expect(model.skipped(in: ["1.4.0", "1.3.0", "1.2.0", "1.1.0"]) == ["1.3.0"])
    }

    @Test func cooldownTakesTheVersionAndDateFromTheNote() throws {
        let model = try Self.model(
            version: "4.2.0",
            row: Self.row(
                locked: "4.2.0", within: "4.3.0", latest: "4.3.0", note: "v4.3.0 eligible 2026-10-30T09:14:00Z",
                extra: #","released":"2026-10-28T09:14:00Z""#),
            range: "^4.2")
        let cooldown = VersionsModel.Cooldown(
            version: "4.3.0", eligible: try Self.date("2026-10-30T09:14:00Z"),
            released: try Self.date("2026-10-28T09:14:00Z"))
        #expect(model.status == .cooldown(cooldown))
        #expect(model.inRangeVersion == "4.3.0")
        #expect(model.latestIsInRange)
        #expect(model.minimumAge?.value == "72h")
        #expect(model.minimumAge?.isEnforced == true)
    }

    @Test func noMinimumAgeWhenThePolicyIsZero() throws {
        let model = try Self.model(row: Self.row(locked: "1.2.0", within: "1.2.0", latest: "1.2.0"), minAge: "0h")
        #expect(model.minimumAge == nil)
    }

    @Test func majorOutsideTheRange() throws {
        let model = try Self.model(
            version: "2.3.1", row: Self.row(locked: "2.3.1", within: "2.3.1", latest: "3.0.0"), range: "^2.0")
        #expect(model.status == .outsideRange("3.0.0"))
        #expect(model.nextMajor == 3)
        #expect(model.showsInRangeRow)
    }

    @Test func tagMovedWinsOverTheAvailableUpdate() throws {
        let model = try Self.model(
            version: "4.0.1",
            row: Self.row(
                locked: "4.0.1", within: "4.1.0", latest: "4.1.0",
                note: "tag 4.0.1 moved from a81f2c0d4e9b to 3fd09e1c7a52"
            ))
        #expect(model.status == .tagMoved(.init(tag: "4.0.1", from: "a81f2c0d4e9b", to: "3fd09e1c7a52")))
        #expect(model.cooldown == nil)
    }

    // MARK: - Tag move

    @Test(arguments: [
        ("tag v1 moved from abc to def", VersionsModel.TagMove(tag: "v1", from: "abc", to: "def")),
        ("tag v4.1.0 moved from a81f2c0 to 3fd09e1 (re-pointed)", .init(tag: "v4.1.0", from: "a81f2c0", to: "3fd09e1")),
    ])
    func tagMoveParsesTheNote(note: String, expected: VersionsModel.TagMove) {
        #expect(VersionsModel.TagMove(note: note) == expected)
    }

    @Test(arguments: [
        "4.3.0 eligible 2026-10-30T09:14:00Z", "tag v1", "the tag v1 moved from a to b", "tag  moved from a to b", "",
    ])
    func tagMoveIgnoresOtherNotes(note: String) {
        #expect(VersionsModel.TagMove(note: note) == nil)
    }

    // MARK: - Full list

    @Test func listedStandingsForACooldownInACaretRange() throws {
        let model = try Self.model(
            version: "4.2.0",
            row: Self.row(
                locked: "4.2.0", within: "4.3.0", latest: "4.3.0", note: "4.3.0 eligible 2026-10-30T09:14:00Z",
                extra: #","released":"2026-10-28T09:14:00Z""#),
            range: "^4.2")
        let listed = model.listed(["4.3.0", "4.2.0", "4.1.2", "3.34.0", "dev-main"])
        let eligible = try Self.date("2026-10-30T09:14:00Z")
        #expect(
            listed.map(\.standing) == [.waiting(eligible: eligible), .installed, .belowRange, .belowRange, .unknown])
        #expect(listed.map(\.released) == [try Self.date("2026-10-28T09:14:00Z"), nil, nil, nil, nil])
    }

    // MARK: - Release dates (D67)

    /// A CLI with `versions-released` only (a GitHub tag list dates none, Composer every one): each row from the map.
    @Test func everyRowIsDatedFromTheMap() throws {
        let dates = [
            "2.0.0": "2026-11-02T12:00:00Z", "1.4.0": "2026-10-24T12:00:00Z", "1.3.0": "2026-10-10T12:00:00Z",
            "1.2.0": "2026-10-01T12:00:00Z",
        ]
        let model = try Self.model(row: Self.row(locked: "1.2.0", within: "1.4.0", latest: "2.0.0"), released: dates)
        #expect(model.installedReleased == (try Self.date("2026-10-01T12:00:00Z")))
        #expect(model.inRangeReleased == (try Self.date("2026-10-24T12:00:00Z")))
        #expect(model.latestReleased == (try Self.date("2026-11-02T12:00:00Z")))
        let listed = model.listed(["2.0.0", "1.4.0", "1.3.0", "1.2.0", "1.1.0"])
        let dated: [Date?] = try ["2.0.0", "1.4.0", "1.3.0", "1.2.0"].compactMap { dates[$0] }.map(Self.date)
        #expect(listed.map(\.released) == dated + [nil])
    }

    /// `within` is not `latest`: each named row gets its own key, never `latest`'s time.
    @Test func withinAndLatestAreDatedApart() throws {
        let model = try Self.model(
            row: Self.row(
                locked: "1.2.0", within: "1.4.0", latest: "2.0.0",
                extra: #","locked-released":"2026-10-01T12:00:00Z","within-released":"2026-10-24T12:00:00Z","#
                    + #""latest-released":"2026-11-02T12:00:00Z""#))
        #expect(model.status == .available("1.4.0"))
        #expect(model.installedReleased == (try Self.date("2026-10-01T12:00:00Z")))
        #expect(model.inRangeReleased == (try Self.date("2026-10-24T12:00:00Z")))
        #expect(model.latestReleased == (try Self.date("2026-11-02T12:00:00Z")))
        let listed = model.listed(["2.0.0", "1.4.0", "1.3.0", "1.2.0"])
        #expect(
            listed.map(\.released) == [
                try Self.date("2026-11-02T12:00:00Z"), try Self.date("2026-10-24T12:00:00Z"), nil,
                try Self.date("2026-10-01T12:00:00Z"),
            ])
    }

    /// The main Composer cooldown: `within` waits and `latest` is a new major. The callout and row date `within`.
    @Test func aCooldownIsDatedFromWithinReleased() throws {
        let model = try Self.model(
            row: Self.row(
                locked: "1.2.0", within: "1.4.0", latest: "2.0.0", note: "1.4.0 eligible 2026-10-30T12:00:00Z",
                extra: #","within-released":"2026-10-27T12:00:00Z","latest-released":"2026-11-02T12:00:00Z""#))
        let cooldown = try #require(model.cooldown)
        #expect(model.status == .cooldown(cooldown))
        #expect(cooldown.released == (try Self.date("2026-10-27T12:00:00Z")))
        #expect(model.inRangeReleased == (try Self.date("2026-10-27T12:00:00Z")))
        #expect(model.latestReleased == (try Self.date("2026-11-02T12:00:00Z")))
    }

    /// The status entry's `released` (the lock's time) dates the installed version first.
    @Test func theLockDatesTheInstalledVersion() throws {
        let model = try Self.model(
            row: Self.row(
                locked: "1.2.0", within: "1.2.0", latest: "1.2.0", extra: #","locked-released":"2026-09-01T12:00:00Z""#),
            statusReleased: "2026-10-01T12:00:00Z", released: ["1.2.0": "2026-08-01T12:00:00Z"])
        #expect(model.installedReleased == (try Self.date("2026-10-01T12:00:00Z")))
        let unchecked = try Self.model(row: nil, statusReleased: "2026-10-01T12:00:00Z")
        #expect(unchecked.installedReleased == (try Self.date("2026-10-01T12:00:00Z")))
    }

    /// A GitHub package locked at its newest tag: the lock dates it, `latest-released` is null and the registry
    /// map is empty. The list row agrees with the Installed row.
    @Test func aListRowFallsThroughAnUndatedNamedRow() throws {
        let model = try Self.model(
            row: Self.row(
                locked: "1.2.0", within: "1.2.0", latest: "1.2.0",
                extra: #","locked-released":"2026-10-01T12:00:00Z","within-released":null,"latest-released":null"#),
            statusReleased: "2026-10-01T12:00:00Z")
        let date = try Self.date("2026-10-01T12:00:00Z")
        #expect(model.latestReleased == nil && model.installedReleased == date)
        #expect(model.listed(["1.2.0", "1.1.0"]).map(\.released) == [date, nil])
    }

    /// A Packagist list spells `v4.3.0`: the waiting version and every date still match.
    @Test func vPrefixedVersionsKeepTheirDatesAndTheWaitingStanding() throws {
        let model = try Self.model(
            version: "v4.2.0",
            row: Self.row(
                locked: "v4.2.0", within: "v4.3.0", latest: "v4.3.0", note: "v4.3.0 eligible 2026-10-30T12:00:00Z"),
            range: "^4.2",
            released: ["v4.3.0": "2026-10-28T12:00:00Z", "v4.2.0": "2026-10-01T12:00:00Z"])
        let eligible = try Self.date("2026-10-30T12:00:00Z")
        let cooldown = try #require(model.cooldown)
        #expect(cooldown.version == "4.3.0")
        #expect(cooldown.released == (try Self.date("2026-10-28T12:00:00Z")))
        #expect(model.installedReleased == (try Self.date("2026-10-01T12:00:00Z")))
        let listed = model.listed(["v4.3.0", "v4.2.0", "v4.1.2"])
        #expect(listed.map(\.standing) == [.waiting(eligible: eligible), .installed, .belowRange])
        #expect(
            listed.map(\.released) == [
                try Self.date("2026-10-28T12:00:00Z"), try Self.date("2026-10-01T12:00:00Z"), nil,
            ])
    }

    @Test func listedStandingsForAnUpdateWithinRange() throws {
        let model = try Self.model(row: Self.row(locked: "1.2.0", within: "1.4.0", latest: "2.0.0"))
        let listed = model.listed(["2.0.0", "1.4.0", "1.3.0", "1.2.0", "1.2.0-rc1", "1.1.0"])
        #expect(listed.map(\.standing) == [.outsideRange, .available, .inRange, .installed, .belowRange, .belowRange])
    }

    @Test func olderVersionsWithoutACaretRangeAreJustOlder() throws {
        let model = try Self.model(row: Self.row(locked: "1.2.0", within: "1.2.0", latest: "1.2.0"), range: "~1.2")
        #expect(model.listed(["1.1.0"]).map(\.standing) == [.older])
    }

    @Test(arguments: [
        ("^4.2", Version(4, 2, 0)..<Version(5, 0, 0)),
        ("^1", Version(1, 0, 0)..<Version(2, 0, 0)),
        ("^0.4", Version(0, 4, 0)..<Version(0, 5, 0)),
        ("^0.0.3", Version(0, 0, 3)..<Version(0, 0, 4)),
    ])
    func caretBounds(range: String, expected: Range<Version>) {
        #expect(VersionsModel.caretBounds(range) == expected)
    }

    @Test(arguments: ["~1.2", ">=1.0", "^x.1", "*", ""])
    func caretBoundsRejectOtherConstraints(range: String) {
        #expect(VersionsModel.caretBounds(range) == nil)
    }
}
