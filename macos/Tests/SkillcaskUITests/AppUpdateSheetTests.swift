import Foundation
import SkillcaskCore
import SkillcaskUpdates
import Testing

@testable import SkillcaskUI

/// The update sheet (U2/U3) and the Settings › Updates app group (U5): what each install method shows, what each
/// button writes to the pasteboard or opens (through `AppUpdateStore.System`, never AppKit in a test) and which
/// state it changes.
@MainActor @Suite struct AppUpdateSheetTests {
    /// Records what the store asked the system for.
    @MainActor final class SystemLog {
        var copied: [String] = []
        var opened: [URL] = []
        var launched: [URL] = []
        var revealed: [URL] = []

        var system: AppUpdateStore.System {
            AppUpdateStore.System(
                copy: { self.copied.append($0) }, open: { self.opened.append($0) },
                openApplication: { self.launched.append($0) }, reveal: { self.revealed.append($0) })
        }

        var isEmpty: Bool {
            copied.isEmpty && opened.isEmpty && launched.isEmpty && revealed.isEmpty
        }
    }

    static let installed = Version(0, 10, 2)
    static let latest = Version(0, 10, 3)
    static let bundled = Locator.Choice.bundled(
        URL(fileURLWithPath: "/Applications/Skillcask.app/Contents/Helpers/skillcask"))
    static let original = URL(fileURLWithPath: "/Users/me/Downloads/Skillcask.app")

    /// In memory: no plist is left behind.
    let suite = MemoryDefaults.make()
    let client = FakeCLIClient()
    let log = SystemLog()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func makeStore(
        method: InstallMethod = .homebrew, state: UpdateState = UpdateState(consent: .declined, latestSeen: latest),
        installed: Version? = AppUpdateSheetTests.installed, binary: Locator.Choice? = AppUpdateSheetTests.bundled,
        cli: Version = AppUpdateSheetTests.installed, ready: Bool = true
    ) -> AppUpdateStore {
        let client = client
        let now = now
        return AppUpdateStore(
            installed: installed, installMethod: method, defaults: UpdateDefaults(suite), state: state,
            system: log.system, now: { now }, sleep: { _ in throw CancellationError() },
            context: {
                ready ? .init(client: client, binary: binary, capabilities: Capabilities(version: cli)) : nil
            })
    }

    /// A store with the sheet open on 0.10.3.
    func presented(_ method: InstallMethod = .homebrew) -> AppUpdateStore {
        let store = makeStore(method: method)
        store.presentSheet(for: Self.latest)
        return store
    }

    // MARK: - Body per install method

    @Test func homebrewShowsTheCommandAndCopyCommandFirst() {
        let content = AppUpdateSheetContent(method: .homebrew, version: Self.latest)
        #expect(content.body == .homebrew(command: "brew update && brew upgrade skillcask skillcask-app"))
        #expect(content.pill == "Installed with Homebrew")
        #expect(content.offersSkip)
        #expect(content.secondary == [.remindTomorrow, .copyAndOpenTerminal])
        #expect(content.primary == .copyCommand)
        #expect(AppUpdateCopy.title(for: content.primary) == "Copy Command")
        #expect(AppUpdateCopy.title(for: .copyAndOpenTerminal) == "Copy and Open Terminal")
    }

    @Test func directNamesTheZipAndOpensTheReleasePage() {
        let content = AppUpdateSheetContent(method: .direct, version: Self.latest)
        #expect(content.body == .direct(zip: "Skillcask-0.10.3-macos-universal.zip"))
        #expect(content.pill == "Installed from a download")
        #expect(content.offersSkip)
        #expect(content.secondary == [.remindTomorrow])
        #expect(content.primary == .openReleasePage)
        #expect(AppUpdateCopy.title(for: content.primary) == "Open Release Page")
        #expect(
            AppUpdateCopy.howToUpdate(zip: "Skillcask-0.10.3-macos-universal.zip")
                == "Download Skillcask-0.10.3-macos-universal.zip from the release page, quit Skillcask, unzip it "
                + "and drag Skillcask into Applications, replacing the old copy. If you installed it with "
                + "skillcask-app-installer.sh, run that again instead.")
    }

    @Test func aVersionThatIsNotStrictNamesNoZip() {
        let content = AppUpdateSheetContent(method: .direct, version: Version(0, 10, 3, prerelease: "rc 1"))
        #expect(content.body == .direct(zip: nil))
        #expect(AppUpdateCopy.howToUpdate(zip: nil).hasPrefix("Download the macOS zip from the release page"))
    }

    @Test func translocatedShowsInFinderOnlyWhenTheOriginalIsKnown() {
        let known = AppUpdateSheetContent(method: .translocated(original: Self.original), version: Self.latest)
        #expect(known.body == .translocated(original: Self.original))
        #expect(known.pill == "Running from a temporary copy")
        #expect(!known.offersSkip)
        #expect(known.secondary == [.remindTomorrow])
        #expect(known.primary == .showInFinder(Self.original))
        #expect(AppUpdateCopy.title(for: known.primary) == "Show in Finder")

        let unknown = AppUpdateSheetContent(method: .translocated(original: nil), version: Self.latest)
        #expect(unknown.body == .translocated(original: nil))
        #expect(unknown.primary == .openReleasePage)
        #expect(unknown.secondary == [.remindTomorrow])
    }

    @Test func theStoreKeepsTheInstallMethodItWasGiven() {
        #expect(makeStore(method: .direct).installMethod == .direct)
        #expect(AppUpdateStore.disabled.installMethod == .direct)
        let content = AppUpdateSheetContent(method: makeStore(method: .homebrew).installMethod, version: Self.latest)
        #expect(content.primary == .copyCommand)
    }

    // MARK: - Actions

    @Test func copyCommandWritesTheExactCommandAndWaitsForTheRelaunch() {
        let store = presented()
        store.perform(.copyCommand, on: Self.latest)
        #expect(log.copied == ["brew update && brew upgrade skillcask skillcask-app"])
        #expect(log.copied.allSatisfy { !$0.hasSuffix("\n") })
        #expect(log.launched.isEmpty && log.opened.isEmpty)
        #expect(store.state.awaitingRelaunch)
        #expect(UpdateDefaults(suite).load().awaitingRelaunch)
        #expect(store.card == .awaitingRelaunch)
        #expect(store.sheet == nil)
    }

    @Test func copyAndOpenTerminalAlsoOpensTerminal() {
        let store = presented()
        store.perform(.copyAndOpenTerminal, on: Self.latest)
        #expect(log.copied == [UpdateLinks.homebrewCommand])
        #expect(log.launched == [URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")])
        #expect(log.opened.isEmpty)
        #expect(store.state.awaitingRelaunch)
        #expect(store.sheet == nil)
    }

    @Test func openReleasePageOpensExactlyTheTagPage() {
        let store = presented(.direct)
        store.perform(.openReleasePage, on: Self.latest)
        #expect(log.opened == [URL(string: "https://github.com/GetResponse/skillcask/releases/tag/v0.10.3")!])
        #expect(log.copied.isEmpty && log.launched.isEmpty)
        #expect(!store.state.awaitingRelaunch)
        #expect(store.sheet == nil)
    }

    @Test func releaseNotesOpenTheTagPageAndKeepTheSheet() {
        let store = presented()
        store.openReleaseNotes(for: Self.latest)
        #expect(log.opened == [URL(string: "https://github.com/GetResponse/skillcask/releases/tag/v0.10.3")!])
        #expect(store.sheet != nil)
    }

    @Test func aVersionThatIsNotStrictOpensNothing() {
        let store = presented(.direct)
        let odd = Version(0, 10, 3, prerelease: "rc 1")
        #expect(!odd.isStrict)
        store.perform(.openReleasePage, on: odd)
        #expect(log.opened.isEmpty)
        #expect(store.sheet == nil)
    }

    @Test func showInFinderRevealsTheOriginal() {
        let store = presented(.translocated(original: Self.original))
        store.perform(.showInFinder(Self.original), on: Self.latest)
        #expect(log.revealed == [Self.original])
        #expect(store.sheet == nil)
    }

    @Test func skipRemembersTheVersionAndHidesTheCard() {
        let store = presented()
        #expect(store.card == .available(Self.latest))
        store.perform(.skip, on: Self.latest)
        #expect(store.state.skippedVersion == Self.latest)
        #expect(UpdateDefaults(suite).load().skippedVersion == Self.latest)
        #expect(store.card == .none)
        #expect(store.sheet == nil)
        #expect(log.isEmpty)
    }

    @Test func remindHidesTheCardForADay() {
        let store = presented()
        store.perform(.remindTomorrow, on: Self.latest)
        #expect(store.state.remindAfter == now.addingTimeInterval(24 * 3600))
        #expect(store.card == .none)
        #expect(store.sheet == nil)
        #expect(log.isEmpty)
    }

    @Test func closingChangesNothing() {
        let store = presented()
        let before = store.state
        store.dismissSheet()
        #expect(store.state == before)
        #expect(store.sheet == nil)
        #expect(log.isEmpty)
        #expect(UpdateDefaults(suite).load() == UpdateState())
    }

    @Test func copyLabelsNameTheCommand() {
        #expect(
            AppUpdateCopy.copyLabel(UpdateLinks.homebrewCommand)
                == "Copy command: brew update && brew upgrade skillcask skillcask-app")
    }

    // MARK: - Settings › Updates (U5)

    @Test func installedLineNamesTheMethod() {
        #expect(AppUpdateCopy.installedLine(Self.installed, .homebrew) == "Skillcask 0.10.2 · Homebrew")
        #expect(AppUpdateCopy.installedLine(Self.installed, .direct) == "Skillcask 0.10.2 · download")
        #expect(
            AppUpdateCopy.installedLine(Self.installed, .translocated(original: nil))
                == "Skillcask 0.10.2 · temporary copy")
    }

    @Test func lastCheckedReadsRelativeThenAbsolute() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)  // 15 Jan 2027, 08:00 GMT
        #expect(AppUpdateCopy.lastChecked(nil, now: at, timeZone: .gmt) == "Never")
        #expect(AppUpdateCopy.lastChecked(at, now: at.addingTimeInterval(3600), timeZone: .gmt) == "Today at 08:00")
        #expect(
            AppUpdateCopy.lastChecked(at, now: at.addingTimeInterval(24 * 3600), timeZone: .gmt)
                == "Yesterday at 08:00")
        #expect(
            AppUpdateCopy.lastChecked(at, now: at.addingTimeInterval(3 * 24 * 3600), timeZone: .gmt)
                == "15 Jan at 08:00")
        #expect(AppUpdateCopy.availableSuffix(Self.latest) == " · 0.10.3 available")
        #expect(AppUpdateCopy.availableSuffix(Self.latest, skipped: true) == " · 0.10.3 available (skipped)")
    }

    @Test func dailySwitchGrantsAndDeclines() {
        let store = makeStore(state: UpdateState())
        #expect(!store.dailyCheck)
        store.dailyCheck = true
        #expect(store.state.consent == .granted)
        #expect(UpdateDefaults(suite).load().consent == .granted)
        #expect(store.schedule != nil)
        store.dailyCheck = false
        #expect(store.state.consent == .declined)
        #expect(UpdateDefaults(suite).load().consent == .declined)
        #expect(store.schedule == nil)
    }

    @Test func resetClearsTheSkippedVersion() {
        let store = makeStore(
            state: UpdateState(consent: .declined, latestSeen: Self.latest, skippedVersion: Self.latest))
        #expect(AppUpdateCopy.skipped(store.state.skippedVersion) == "0.10.3")
        #expect(store.card == .none)
        store.resetSkipped()
        #expect(store.state.skippedVersion == nil)
        #expect(AppUpdateCopy.skipped(store.state.skippedVersion) == "None")
        #expect(store.card == .available(Self.latest))
    }

    /// B1 of phase 4b: Check Now answers in Settings and leaves no alert or sheet pending for the main window.
    @Test func checkNowAnswersInSettingsOnly() async {
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.2","newer":false}"#)
        let store = makeStore(state: UpdateState())
        #expect(store.checkNowBlocker == nil)
        await store.checkFromSettings()
        #expect(await client.commands == [.selfCheck])
        #expect(store.state.lastCheckAt == now)
        #expect(store.settingsCheckResult == .upToDate)
        #expect(store.settingsCheckResult?.message == "You’re up to date")
        #expect(store.alert == nil && store.sheet == nil)
        #expect(!store.isChecking)
    }

    @Test func checkNowFindingAnUpdateOpensNothingUntilAsked() async {
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.3","newer":true}"#)
        let store = makeStore(state: UpdateState(consent: .declined, latestSeen: Self.latest))
        await store.checkFromSettings()
        #expect(store.settingsCheckResult == .available(Self.latest))
        #expect(store.settingsCheckResult?.message == "Skillcask 0.10.3 is available")
        #expect(store.alert == nil && store.sheet == nil, "a known update still runs the check, no sheet")
        store.seeWhatsNew()
        #expect(store.sheet?.version == Self.latest)
    }

    @Test func checkNowFailureShowsTheErrorLineInSettings() async {
        let error = CLIError.binaryMissing(searched: [])
        await client.script(.selfCheck, in: .personal, .error(error))
        let store = makeStore(state: UpdateState())
        await store.checkFromSettings()
        #expect(store.settingsCheckResult == .failed(AppUpdateCopy.failedMessage(error)))
        #expect(store.alert == nil && store.sheet == nil)
        #expect(store.state.lastCheckAt == nil)
    }

    @Test func checkNowAnswerClearsWhenALaterCheckFindsAnUpdate() async {
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.2","newer":false}"#)
        let store = makeStore(state: UpdateState(consent: .granted))
        await store.checkFromSettings()
        #expect(store.settingsCheckResult == .upToDate)
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.3","newer":true}"#)
        await store.automaticCheck()
        #expect(store.state.latestSeen == Self.latest)
        #expect(store.settingsCheckResult == nil, "no \"up to date\" next to `· 0.10.3 available`")
    }

    @Test func checkNowAnswerClearsOnSkipAndReset() async {
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.3","newer":true}"#)
        let store = makeStore()
        await store.checkFromSettings()
        #expect(store.settingsCheckResult == .available(Self.latest))
        store.skip(Self.latest)
        #expect(store.settingsCheckResult == nil)
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.3","newer":true}"#)
        await store.checkFromSettings()
        #expect(store.settingsCheckResult == .available(Self.latest))
        store.resetSkipped()
        #expect(store.settingsCheckResult == nil)
    }

    @Test func checkNowAnswerStaysWhenNothingChanges() async {
        await client.json(.selfCheck, in: .personal, #"{"version":"0.10.2","latest":"0.10.3","newer":true}"#)
        let store = makeStore()
        await store.checkFromSettings()
        store.remindTomorrow()
        #expect(store.settingsCheckResult == .available(Self.latest))
    }

    @Test func seeWhatsNewWithoutAKnownUpdateOpensNothing() {
        let store = makeStore(state: UpdateState())
        store.seeWhatsNew()
        #expect(store.sheet == nil)
    }

    @Test func checkNowSaysWhyItCannotRun() {
        let notReady = makeStore(ready: false)
        #expect(notReady.checkNowBlocker == AppUpdateCopy.checkNeedsCLI)
        let old = makeStore(
            binary: .configured(URL(fileURLWithPath: "/opt/homebrew/bin/skillcask")), cli: Version(0, 10, 1))
        #expect(old.checkNowBlocker == AppUpdateCopy.checkNeedsNewerCLI)
    }
}
