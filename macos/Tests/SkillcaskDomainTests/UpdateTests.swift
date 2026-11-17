import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskDomain

/// `outdated` as the CLI prints it (`src/commands.rs` 1741–1747): `within` is the newest version the constraint
/// allows WITHOUT the minimum release age, and the note `<within> eligible <date>` says it still waits; the CLI's
/// own test pins it (`tests/json.rs`: locked 1.0.0, within 1.1.0, note "1.1.0 eligible …"). Such a row is a
/// cooldown, never an update.
@Suite struct UpdateTests {
    static let eligible = "2026-10-30T09:14:00Z"

    @Test func withinInsideTheMinimumAgeIsACooldownNotAnUpdate() throws {
        let row = try update(locked: "1.0.0", within: "1.1.0", latest: "1.1.0", note: "1.1.0 eligible \(Self.eligible)")
        #expect(row.available == nil)
        #expect(row.cooldown == .init(version: "1.1.0", eligible: ISO8601DateFormatter().date(from: Self.eligible)))
        #expect(row.outsideRange == nil)
        #expect(HealthMapping.health(state: .ok, update: row, findings: []) == .cooldown(until: row.note))
    }

    @Test func aGitHubSpellingWithVIsTheSameVersion() throws {
        let row = try update(
            locked: "v4.2.0", within: "v4.3.0", latest: "v4.3.0", note: "v4.3.0 eligible \(Self.eligible)")
        #expect(row.available == nil && row.cooldown?.version == "v4.3.0")
        #expect(Update.bare("v4.3.0") == "4.3.0" && Update.bare("4.3.0") == "4.3.0")
    }

    @Test func aNoteNamingTheLockedVersionIsNoCooldown() throws {
        // The locked version itself is younger than the minimum age: nothing newer waits.
        let row = try update(locked: "1.1.0", within: "1.1.0", latest: "1.1.0", note: "1.1.0 eligible \(Self.eligible)")
        #expect(row.cooldown == nil && row.available == nil)
        #expect(HealthMapping.health(state: .ok, update: row, findings: []) == .installed)
    }

    @Test(arguments: [
        "1.1.0 eligible", "eligible \(eligible)", "1.1.0 eligible \(eligible) later", "the 1.1.0 eligible \(eligible)",
        "tag 1.0.0 moved from a81f2c0d4e9b to 3fd09e1c7a52", "",
    ])
    func otherNotesNameNoWaitingVersion(note: String) throws {
        let row = try update(locked: "1.0.0", within: "1.1.0", latest: "1.1.0", note: note)
        #expect(row.cooldown == nil)
        #expect(row.available?.to == "1.1.0", "an unknown note never hides an update")
    }

    @Test func thePlannedEligibleKeyDatesWithin() throws {
        let row = try update(locked: "1.0.0", within: "1.1.0", latest: "1.1.0", eligible: Self.eligible)
        #expect(row.cooldown?.version == "1.1.0" && row.available == nil)
        let current = try update(locked: "1.1.0", within: "1.1.0", latest: "1.1.0", eligible: Self.eligible)
        #expect(current.cooldown == nil)
    }

    @Test func settledWhenStatusShowsTheOfferedVersion() throws {
        let row = try update(locked: "1.2.0", within: "1.4.0", latest: "1.4.0")
        #expect(row.settled(installed: "1.4.0").available == nil)
        #expect(row.settled(installed: "1.4.0").locked == "1.4.0")
        #expect(row.settled(installed: "1.3.0").available?.to == "1.4.0", "another version leaves the update")
        #expect(row.settled(installed: nil) == row)
        let tagged = try update(locked: "v1.2.0", within: "v1.4.0", latest: "v1.4.0")
        #expect(tagged.settled(installed: "v1.4.0").available == nil)
    }

    /// D67's three dates decode, and a settled row's new `locked` (`within`) keeps `within`'s time.
    @Test func settledCarriesTheReleaseDates() throws {
        let json = #"""
            {"package":"a/b","locked":"v1.2.0","within":"v1.4.0","latest":"v2.0.0","note":null,
            "locked-released":"2026-10-01T12:00:00Z","within-released":"2026-10-24T12:00:00Z",
            "latest-released":"2026-11-02T12:00:00Z"}
            """#
        let row = Update(try JSONDecoder().decode(OutdatedDocument.Package.self, from: Data(json.utf8)))
        let locked = try Date("2026-10-01T12:00:00Z", strategy: .iso8601)
        let within = try Date("2026-10-24T12:00:00Z", strategy: .iso8601)
        let latest = try Date("2026-11-02T12:00:00Z", strategy: .iso8601)
        #expect(row.lockedReleased == locked && row.withinReleased == within && row.latestReleased == latest)
        #expect(row.released == nil, "the old planned key is not D67's latest-released")
        let settled = row.settled(installed: "v1.4.0")
        #expect(settled.locked == "v1.4.0")
        #expect(settled.lockedReleased == within && settled.withinReleased == within)
        #expect(settled.latestReleased == latest)
        #expect(row.settled(installed: "v1.3.0").lockedReleased == locked, "another version leaves the dates")
        let old = try update(locked: "1.2.0", within: "1.4.0", latest: "1.4.0")
        #expect(old.lockedReleased == nil && old.withinReleased == nil && old.latestReleased == nil)
    }

    @Test func aFreshStatusTurnsTheRowGreenBeforeTheNextCheck() throws {
        let status = #"""
            {"ok":true,"entries":[{"package":"acme/pdf","skill":"pdf","version":"1.4.0","state":"ok","ok":true},
            {"package":"acme/lint","skill":"lint","version":"2.0.0","state":"ok","ok":true}],
            "policy":{},"repositories":[]}
            """#
        // The last `outdated` was read before the update: pdf 1.2.0 → 1.4.0 is stale, lint's update is not.
        let outdated = #"""
            {"behind":[],"packages":[{"package":"acme/pdf","locked":"1.2.0","within":"1.4.0","latest":"1.4.0"},
            {"package":"acme/lint","locked":"2.0.0","within":"2.1.0","latest":"2.1.0"}]}
            """#
        let snapshot = try ScopeSnapshot(
            status: Sample.decode(StatusDocument.self, status), audit: nil, doctor: nil,
            outdated: Sample.decode(OutdatedDocument.self, outdated))
        #expect(snapshot.entry(id: "pdf")?.health == .installed)
        #expect(snapshot.entry(id: "lint")?.health == .updateAvailable(from: "2.0.0", to: "2.1.0"))
        #expect(snapshot.availableUpdates.map(\.package) == ["acme/lint"])
        #expect(snapshot.attention.updates == 1)
    }
}
