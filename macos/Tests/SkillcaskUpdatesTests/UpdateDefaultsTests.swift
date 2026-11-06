import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskUpdates

/// `UpdateDefaults`: every field round-trips under `appUpdates.*`, unset fields leave no key, and the launch hook
/// clears the waiting card for good.
@Suite struct UpdateDefaultsTests {
    /// In memory: no plist is left behind.
    let memory = MemoryDefaults.make()

    func defaults() throws -> UserDefaults {
        memory
    }

    @Test func aFreshSuiteIsUndecidedAndEmpty() throws {
        #expect(UpdateDefaults(try defaults()).load() == UpdateState())
    }

    @Test func everyFieldRoundTrips() throws {
        let defaults = try defaults()
        let state = UpdateState(
            consent: .granted, lastCheckAt: Date(timeIntervalSince1970: 1_800_000_000),
            latestSeen: Version(1, 3, 0, prerelease: "rc.2"), skippedVersion: Version(1, 2, 9),
            hiddenUntil: Date(timeIntervalSince1970: 1_800_600_000), hiddenForVersion: Version(1, 3, 0),
            remindAfter: Date(timeIntervalSince1970: 1_800_086_400), awaitingRelaunch: true,
            managed: "Jamf installs updates")
        UpdateDefaults(defaults).save(state)
        #expect(UpdateDefaults(defaults).load() == state)
        #expect(defaults.string(forKey: "appUpdates.consent") == "granted")
        #expect(defaults.string(forKey: "appUpdates.latestSeen") == "1.3.0-rc.2")
        #expect(UpdateDefaults.Key.all.allSatisfy { $0.hasPrefix("appUpdates.") && defaults.object(forKey: $0) != nil })
        #expect(Set(UpdateDefaults.Key.all).count == 9)

        var declined = state
        declined.consent = .declined
        UpdateDefaults(defaults).save(declined)
        #expect(UpdateDefaults(defaults).load().consent == .declined)
    }

    @Test func unsetFieldsLeaveNoKey() throws {
        let defaults = try defaults()
        UpdateDefaults(defaults)
            .save(UpdateState(consent: .granted, skippedVersion: Version(1, 0, 0), awaitingRelaunch: true))
        UpdateDefaults(defaults).save(UpdateState())
        for key in UpdateDefaults.Key.all {
            #expect(defaults.object(forKey: key) == nil, "\(key)")
        }
    }

    /// A value edited by hand that is not a plain version or a known consent reads as unset.
    @Test func handEditedValuesReadStrictly() throws {
        let defaults = try defaults()
        defaults.set("yes", forKey: "appUpdates.consent")
        defaults.set("v1.3.0", forKey: "appUpdates.latestSeen")
        defaults.set("1.3", forKey: "appUpdates.skippedVersion")
        defaults.set("tomorrow", forKey: "appUpdates.remindAfter")
        #expect(UpdateDefaults(defaults).load() == UpdateState())
    }

    /// The launch hook clears `awaitingRelaunch` and writes it, so the next load agrees; the rest stays.
    @Test func theLaunchHookClearsAwaitingRelaunch() throws {
        let defaults = try defaults()
        let before = UpdateState(consent: .granted, skippedVersion: Version(1, 3, 0), awaitingRelaunch: true)
        UpdateDefaults(defaults).save(before)
        let after = UpdateDefaults(defaults).launched()
        var expected = before
        expected.awaitingRelaunch = false
        #expect(after == expected)
        #expect(UpdateDefaults(defaults).load() == expected)
        #expect(defaults.object(forKey: UpdateDefaults.Key.awaitingRelaunch) == nil)
    }
}
