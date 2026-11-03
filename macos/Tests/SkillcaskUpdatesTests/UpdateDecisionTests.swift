import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskUpdates

/// The card rules of D51 and the U1–U5 boards' acceptance cases (AC) that hold without a view (6, 7, 8, 9).
@Suite struct UpdateDecisionTests {
    let installed = Version(1, 2, 1)
    let v130 = Version(1, 3, 0)
    let v131 = Version(1, 3, 1)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 24 * 60 * 60

    func state(_ latest: Version? = Version(1, 3, 0), consent: UpdateConsent = .granted) -> UpdateState {
        UpdateState(consent: consent, lastCheckAt: now, latestSeen: latest)
    }

    func card(_ state: UpdateState, at date: Date? = nil) -> UpdateCard {
        UpdateDecision.card(installed: installed, state: state, now: date ?? now)
    }

    @Test func aNewerVersionShowsTheCard() {
        #expect(card(state()) == .available(v130))
        #expect(card(state(Version(1, 3, 0, prerelease: "rc.1"))) == .available(Version(1, 3, 0, prerelease: "rc.1")))
    }

    @Test func theSameOrAnOlderVersionShowsNothing() {
        for latest in [installed, Version(1, 2, 0), Version(1, 2, 1, prerelease: "rc.9")] {
            #expect(card(state(latest)) == .none, "\(latest)")
        }
        #expect(card(state(nil)) == .none)
    }

    /// `swift run`, fixtures: no installed version, nothing at all, not even the consent prompt.
    @Test func noInstalledVersionTurnsEverythingOff() {
        for state in [state(), state(consent: .undecided), UpdateState(awaitingRelaunch: true)] {
            #expect(UpdateDecision.card(installed: nil, state: state, now: now) == .none)
        }
        #expect(UpdateDecision.knownUpdate(installed: nil, latest: v130) == nil)
    }

    /// Only an undecided consent asks; either answer is remembered and never asks again.
    @Test func theConsentPromptOnlyWhileUndecided() {
        #expect(card(state(nil, consent: .undecided)) == .consentPrompt)
        #expect(card(state(installed, consent: .undecided)) == .consentPrompt)
        #expect(card(state(nil, consent: .granted)) == .none)
        #expect(card(state(nil, consent: .declined)) == .none)
        #expect(card(state(consent: .undecided)) == .available(v130), "an update a manual check found wins the slot")
    }

    /// AC 6: Skip This Version → no card for 1.3.0; 1.3.1 brings it back; Reset brings 1.3.0 back.
    @Test func skipHidesThatVersionOnly() {
        var skipped = state()
        skipped.skip(v130)
        #expect(card(skipped) == .none)
        #expect(card(skipped, at: now + 365 * day) == .none, "a skip does not expire")
        var newer = skipped
        newer.latestSeen = v131
        #expect(card(newer) == .available(v131))
        skipped.resetSkipped()
        #expect(card(skipped) == .available(v130))
    }

    /// AC 7: × hides for 7 days or until a newer version; the menu still offers 1.3.0.
    @Test func closeHidesForSevenDaysOrUntilANewerVersion() {
        var hidden = state()
        hidden.hide(v130, at: now)
        #expect(card(hidden) == .none)
        #expect(card(hidden, at: now + 6 * day) == .none)
        #expect(card(hidden, at: now + 7 * day - 1) == .none)
        #expect(card(hidden, at: now + 7 * day) == .available(v130))
        #expect(UpdateDecision.knownUpdate(installed: installed, latest: hidden.latestSeen) == v130)
        var newer = hidden
        newer.latestSeen = v131
        #expect(card(newer) == .available(v131), "a newer version shows at once")
    }

    @Test func remindHidesAnyVersionForADay() {
        var reminded = state()
        reminded.remindTomorrow(at: now)
        #expect(card(reminded) == .none)
        reminded.latestSeen = v131
        #expect(card(reminded, at: now + day - 1) == .none)
        #expect(card(reminded, at: now + day) == .available(v131))
    }

    /// A hide or remind date further ahead than its interval was set by a clock that has since gone back: expired.
    @Test func aClockThatWentBackDoesNotHideForever() {
        var hidden = state()
        hidden.hide(v130, at: now + 365 * day)
        #expect(card(hidden) == .available(v130))
        hidden.hide(v130, at: now - day)
        #expect(card(hidden) == .none, "6 days left: still hidden")
        var reminded = state()
        reminded.remindTomorrow(at: now + 30 * day)
        #expect(card(reminded) == .available(v130))
        reminded.remindTomorrow(at: now)
        #expect(card(reminded) == .none)
        reminded.remindTomorrow(at: now + 1)
        #expect(card(reminded) == .available(v130), "1 s beyond the interval")
    }

    /// Waiting for the update until the next launch, over every other state; the launch hook clears it.
    @Test func awaitingRelaunchUntilTheNextLaunch() {
        var copied = state()
        copied.skip(v130)
        copied.copiedCommand()
        #expect(card(copied) == .awaitingRelaunch)
        #expect(card(copied, at: now + 30 * day) == .awaitingRelaunch)
        var undecided = UpdateState()
        undecided.copiedCommand()
        #expect(card(undecided) == .awaitingRelaunch)
        copied.launched()
        #expect(card(copied) == .none, "still skipped after the relaunch")
    }

    /// The manual check ignores skip, × and Remind, and compares with the app, not the CLI's `newer`.
    @Test func aManualCheckIgnoresSkipHideAndRemind() {
        let document = SelfCheckDocument(version: "1.2.0", latest: "1.3.0", newer: true)
        #expect(UpdateDecision.manual(installed: installed, document: document) == .available(v130))
        let same = SelfCheckDocument(version: "1.0.0", latest: "1.2.1", newer: true)
        #expect(UpdateDecision.manual(installed: installed, document: same) == .upToDate(installed))
        let older = SelfCheckDocument(version: "1.2.1", latest: "1.2.0", newer: false)
        #expect(UpdateDecision.manual(installed: installed, document: older) == .upToDate(installed))
        let unknown = SelfCheckDocument(version: "1.2.1", latest: nil, newer: false)
        #expect(UpdateDecision.manual(installed: installed, document: unknown) == .unknown)
        let loose = SelfCheckDocument(version: "1.2.1", latest: "v9.0.0", newer: true)
        #expect(UpdateDecision.manual(installed: installed, document: loose) == .unknown)
    }

    /// A version built in code with a prerelease no cask can hold is never offered.
    @Test func aNonStrictLatestIsNeverOffered() {
        let odd = Version(9, 0, 0, prerelease: "rc_1")
        #expect(UpdateDecision.knownUpdate(installed: installed, latest: odd) == nil)
        #expect(card(state(odd)) == .none)
    }
}

/// AC 9 and the effect of a check's outcome on the remembered state.
@Suite struct UpdateRecordTests {
    let installed = Version(1, 2, 1)
    let then = Date(timeIntervalSince1970: 1_800_000_000)
    let now = Date(timeIntervalSince1970: 1_800_100_000)

    /// AC 9: offline (or timed out, or an older CLI) → nothing changes, so the card does not either.
    @Test(arguments: [
        Result<SelfCheckOutcome, CLIError>
            .failure(
                .failed(code: .network, message: "io: offline", hint: "check the connection", stderr: "")),
        .failure(.timedOut(after: .seconds(120))), .failure(.cancelled), .success(.unsupported),
    ])
    func aFailedCheckChangesNothing(result: Result<SelfCheckOutcome, CLIError>) {
        let before = UpdateState(consent: .granted, lastCheckAt: then, latestSeen: Version(1, 3, 0))
        var after = before
        after.record(result, at: now)
        #expect(after == before)
        #expect(UpdateDecision.card(installed: installed, state: after, now: now) == .available(Version(1, 3, 0)))
    }

    @Test func anAnswerRecordsTheTimeAndTheLatest() {
        var state = UpdateState(consent: .granted, lastCheckAt: then, latestSeen: Version(1, 3, 0))
        state.record(.success(.checked(SelfCheckDocument(version: "1.2.1", latest: "1.3.1", newer: true))), at: now)
        #expect(state.lastCheckAt == now && state.latestSeen == Version(1, 3, 1))
        state.record(.success(.checked(SelfCheckDocument(version: "1.2.1", latest: nil, newer: false))), at: then)
        #expect(state.lastCheckAt == then, "the CLI answered")
        #expect(state.latestSeen == Version(1, 3, 1), "an unreadable cask keeps the last known version")
    }
}

/// The daily schedule and AC 8.
@Suite struct UpdateScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let hour: TimeInterval = 60 * 60

    @Test func dueAfterADay() {
        #expect(UpdateSchedule.isDue(lastCheckAt: nil, now: now))
        #expect(!UpdateSchedule.isDue(lastCheckAt: now, now: now))
        #expect(!UpdateSchedule.isDue(lastCheckAt: now - 24 * hour + 1, now: now))
        #expect(UpdateSchedule.isDue(lastCheckAt: now - 24 * hour, now: now))
        #expect(UpdateSchedule.isDue(lastCheckAt: now + hour, now: now), "a clock that went back")
    }

    @Test func theNextCheck() {
        #expect(UpdateSchedule.nextCheck(lastCheckAt: nil, now: now) == now)
        #expect(UpdateSchedule.nextCheck(lastCheckAt: now - hour, now: now) == now + 23 * hour)
        #expect(UpdateSchedule.nextCheck(lastCheckAt: now - 30 * hour, now: now) == now)
        #expect(UpdateSchedule.nextCheck(lastCheckAt: now + hour, now: now) == now)
    }

    /// AC 8: without consent no automatic check, however long ago the last one was.
    @Test func noAutomaticCheckWithoutConsent() {
        for consent in [UpdateConsent.undecided, .declined] {
            for last in [nil, now - 48 * hour] {
                let state = UpdateState(consent: consent, lastCheckAt: last)
                #expect(
                    !UpdateSchedule.shouldCheckAutomatically(state, now: now), "\(consent) \(String(describing: last))")
            }
        }
        #expect(UpdateSchedule.shouldCheckAutomatically(UpdateState(consent: .granted), now: now))
        #expect(
            UpdateSchedule.shouldCheckAutomatically(
                UpdateState(consent: .granted, lastCheckAt: now - 48 * hour), now: now))
        #expect(
            !UpdateSchedule.shouldCheckAutomatically(UpdateState(consent: .granted, lastCheckAt: now - hour), now: now))
    }
}

@Suite struct UpdateLinksTests {
    @Test func theHomebrewCommand() {
        #expect(UpdateLinks.homebrewCommand == "brew update && brew upgrade skillcask skillcask-app")
    }

    @Test func theReleasePageFromAStrictVersionOnly() {
        #expect(
            UpdateLinks.releasePage(for: Version(0, 10, 2))?.absoluteString
                == "https://github.com/GetResponse/skillcask/releases/tag/v0.10.2")
        #expect(
            UpdateLinks.releasePage(for: Version(1, 0, 0, prerelease: "rc.1"))?.absoluteString
                == "https://github.com/GetResponse/skillcask/releases/tag/v1.0.0-rc.1")
        #expect(UpdateLinks.releasePage(for: Version(1, 0, 0, prerelease: "rc/../../x")) == nil)
        #expect(UpdateLinks.releasePage(for: Version(1, 0, 0, prerelease: "")) == nil)
        #expect(UpdateLinks.zipName(for: Version(0, 10, 2)) == "Skillcask-0.10.2-macos-universal.zip")
        #expect(UpdateLinks.zipName(for: Version(1, 0, 0, prerelease: "a b")) == nil)
    }
}

/// `CFBundleShortVersionString` of an `.app` only.
@Suite struct AppVersionTests {
    @Test func theBundleVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.10.1"]
        #expect(AppVersion.read(info: info, bundlePath: "/Applications/Skillcask.app") == Version(0, 10, 1))
        #expect(
            AppVersion.read(info: ["CFBundleShortVersionString": "0.10.1-rc.1"], bundlePath: "/tmp/Skillcask.app/")
                == Version(0, 10, 1, prerelease: "rc.1"))
    }

    /// `swift run` (a build folder, no Info.plist version) and anything that is not a release's version: off.
    @Test func offWithoutAnAppOrAStrictVersion() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.10.1"]
        #expect(AppVersion.read(info: info, bundlePath: "/Users/me/skillcask/macos/.build/debug") == nil)
        #expect(AppVersion.read(info: nil, bundlePath: "/Applications/Skillcask.app") == nil)
        #expect(AppVersion.read(info: [:], bundlePath: "/Applications/Skillcask.app") == nil)
        for loose in ["v0.10.1", "0.10", "1.0", "0.10.1 (dev)"] {
            #expect(
                AppVersion.read(info: ["CFBundleShortVersionString": loose], bundlePath: "/Applications/Skillcask.app")
                    == nil, "\(loose)")
        }
        #expect(
            AppVersion.read(info: ["CFBundleShortVersionString": 10], bundlePath: "/Applications/Skillcask.app") == nil)
    }
}
