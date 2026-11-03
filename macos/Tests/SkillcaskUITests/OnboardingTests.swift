import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// S13 onboarding: detection → sheet state, Try Again, Locate… validation, what the sheet blocks, the
/// sidebar hint rule and the Homebrew commands.
@Suite @MainActor struct OnboardingTests {
    nonisolated static let good = URL(fileURLWithPath: "/good/skillcask")
    nonisolated static let old = URL(fileURLWithPath: "/old/skillcask")
    nonisolated static let noise = URL(fileURLWithPath: "/noise/skillcask")

    /// Finds nothing on its own; only the three files above are executable.
    static let locator = Locator(bundled: nil) { [good.path, old.path, noise.path].contains($0.path) }

    static func versionClient(_ outputs: String...) async -> FakeCLIClient {
        let client = FakeCLIClient()
        for output in outputs {
            await client.script(.version, in: .personal, .result(stdout: output, exit: 0, lines: []))
        }
        return client
    }

    /// An app whose boot finds nothing, with one client per Locate… candidate.
    static func missingApp(settings: SettingsStore = AppStoreTests.settings()) async -> AppStore {
        let clients: [String: FakeCLIClient] = [
            good.path: await versionClient("skillcask 0.9.4 (abc)\n"),
            old.path: await versionClient("skillcask 0.8.0 (abc)\n"),
            noise.path: await versionClient("usage: something else\n"),
        ]
        let app = AppStore(settings: settings, locator: locator) { clients[$0.path] ?? FakeCLIClient() }
        await app.boot()
        return app
    }

    // MARK: - Detection → state

    @Test func detectionMapsToTheSheetState() {
        let binary = Locator.Choice.onPath(Self.old)
        #expect(OnboardingState.resolve(.missing(searched: ["/a"]), binary: nil) == .missing)
        #expect(
            OnboardingState.resolve(.tooOld(found: Version(0, 7, 2), needs: Version(0, 9, 4)), binary: binary)
                == .tooOld(found: Version(0, 7, 2), needs: Version(0, 9, 4), path: "/old/skillcask"))
        #expect(OnboardingState.resolve(.locating, binary: binary) == nil)
        #expect(OnboardingState.resolve(.ready(Capabilities(version: Version(0, 9, 4))), binary: binary) == nil)
    }

    @Test func missingBinaryShowsTheOnboardingSheet() async {
        let app = await Self.missingApp()
        #expect(app.isOnboarding)
        #expect(OnboardingState.resolve(app.cli, binary: app.binary) == .missing)
    }

    @Test func tooOldBinaryShowsFoundAndNeeded() async {
        let client = await Self.versionClient("skillcask 0.7.2 (abc)\n")
        let app = AppStore(settings: AppStoreTests.settings(), locator: AppStoreTests.found) { _ in client }
        await app.boot()
        #expect(app.isOnboarding)
        #expect(
            OnboardingState.resolve(app.cli, binary: app.binary)
                == .tooOld(found: Version(0, 7, 2), needs: Capabilities.minimum, path: "/fake/skillcask"))
    }

    @Test func aReadyBinaryShowsNoSheet() async {
        let client = await Self.versionClient("skillcask 0.9.4 (abc)\n")
        let app = AppStore(settings: AppStoreTests.settings(), locator: AppStoreTests.found) { _ in client }
        await app.boot()
        #expect(!app.isOnboarding)
        #expect(!app.isPresenting)
    }

    // MARK: - Try Again

    @Test func tryAgainDetectsAgainAndClosesTheSheetWhenReady() async {
        let client = await Self.versionClient("skillcask 0.8.0 (abc)\n", "skillcask 0.9.4 (abc)\n")
        let app = AppStore(settings: AppStoreTests.settings(), locator: AppStoreTests.found) { _ in client }
        await app.boot()
        #expect(app.isOnboarding)
        await app.boot()
        #expect(app.cli == .ready(Capabilities(version: Version(0, 9, 4))))
        #expect(!app.isOnboarding)
        #expect(app.selectedScope == .personal)
        #expect(await client.commands == [.version, .version])
    }

    @Test func tryAgainThatStillFailsKeepsTheSheet() async {
        let client = await Self.versionClient("skillcask 0.8.0 (abc)\n", "skillcask 0.8.0 (abc)\n")
        let app = AppStore(settings: AppStoreTests.settings(), locator: AppStoreTests.found) { _ in client }
        await app.boot()
        await app.boot()
        #expect(app.isOnboarding)
        #expect(await client.commands == [.version, .version])
    }

    @Test func aDoubleTryAgainDetectsOnce() async {
        let gate = Gate()
        let client = FakeCLIClient()
        await client.script(.version, in: .personal, .result(stdout: "skillcask 0.8.0 (abc)\n", exit: 0, lines: []))
        await client.script(
            .version, in: .personal, .result(stdout: "skillcask 0.9.4 (abc)\n", exit: 0, lines: []), gate: gate)
        let app = AppStore(settings: AppStoreTests.settings(), locator: AppStoreTests.found) { _ in client }
        await app.boot()
        let first = Task { await app.tryAgain() }
        await gate.arrived()
        #expect(app.isRedetecting)
        await app.tryAgain()
        #expect(await app.locate(executable: Self.good) == .cancelled)
        await gate.open()
        await first.value
        #expect(!app.isRedetecting)
        #expect(app.isReady)
        #expect(await client.commands == [.version, .version])
    }

    // MARK: - Locate…

    @Test func locateStoresThePickedLinkNotItsTarget() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OnboardingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appending(path: "Cellar-skillcask")
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let link = folder.appending(path: "skillcask")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let client = await Self.versionClient("skillcask 0.9.4 (abc)\n")
        let settings = AppStoreTests.settings()
        let app = AppStore(settings: settings, locator: Locator(bundled: nil)) { _ in client }
        let error = await app.locate(executable: link)
        #expect(error == nil)
        #expect(settings.binaryPath == link.path)
        #expect(settings.binaryPath != target.path)
        #expect(app.binary == .configured(link))
    }

    @Test func locateRejectsAFileThatIsNotExecutable() async {
        let settings = AppStoreTests.settings()
        let app = await Self.missingApp(settings: settings)
        let error = await app.locate(executable: URL(fileURLWithPath: "/tmp/notes.txt"))
        #expect(error == .binaryMissing(searched: ["/tmp/notes.txt"]))
        #expect(settings.binaryPath == nil)
        #expect(app.isOnboarding)
    }

    @Test func locateRejectsAFileThatPrintsNoVersion() async {
        let settings = AppStoreTests.settings()
        let app = await Self.missingApp(settings: settings)
        let error = await app.locate(executable: Self.noise)
        #expect(error == .unreadableVersion(output: "usage: something else\n"))
        #expect(settings.binaryPath == nil)
        #expect(OnboardingState.resolve(app.cli, binary: app.binary) == .missing)
        #expect(app.isOnboarding)
        #expect(error.map(OnboardingCopy.locateFailure) == OnboardingCopy.notATool)
    }

    @Test func locateRefusesTheAppItselfWithItsOwnReason() async {
        let settings = AppStoreTests.settings()
        let good = Self.good
        let probed = await Self.versionClient("skillcask 0.9.4 (abc)\n")
        let locator = Locator(bundled: nil, isExecutable: { _ in true }, isSelf: { $0.path == good.path })
        let app = AppStore(settings: settings, locator: locator) { _ in probed }
        let error = await app.locate(executable: good)
        #expect(error == .binaryIsApp(path: good.path))
        #expect(settings.binaryPath == nil)
        #expect(error.map(OnboardingCopy.locateFailure) == ErrorCopy.binaryIsAppTitle)
        #expect(error.map { ErrorCopy.message(for: $0).title } == ErrorCopy.binaryIsAppTitle)
        #expect(ErrorCopy.binaryIsAppTitle != OnboardingCopy.notATool)
    }

    @Test func locateRejectsATooOldCopy() async {
        let settings = AppStoreTests.settings()
        let app = await Self.missingApp(settings: settings)
        let error = await app.locate(executable: Self.old)
        #expect(error == .tooOld(found: Version(0, 8, 0), needs: Capabilities.minimum))
        #expect(settings.binaryPath == nil)
        #expect(app.isOnboarding)
        #expect(
            error.map(OnboardingCopy.locateFailure) == "That copy is 0.8.0; Skillcask needs 0.9.4 or newer.")
    }

    @Test func locateWritesThePathOnlyWhenItValidates() async {
        let settings = AppStoreTests.settings()
        let app = await Self.missingApp(settings: settings)
        let error = await app.locate(executable: Self.good)
        #expect(error == nil)
        #expect(settings.binaryPath == "/good/skillcask")
        #expect(app.binary == .configured(Self.good))
        #expect(app.isReady && !app.isOnboarding)
        #expect(app.selectedScope == .personal)
    }

    // MARK: - What the sheet blocks

    @Test func onboardingBlocksPresentationsToolbarAndMenus() async {
        let app = await Self.missingApp()
        #expect(app.isPresenting)
        #expect(!app.isReady)
        #expect(app.selectedStore == nil)
        #expect(app.request(.addSkill(query: nil)) == false)
        #expect(app.request(.updateAll) == false)
        #expect(app.presentation == nil)
        #expect(!ToolbarRules.isLoaded(app.selectedStore?.snapshot))
    }

    @Test func aReadyAppStillPresents() async {
        let stores = Boot.fixtures(selecting: .personal, selection: nil)
        #expect(!stores.app.isOnboarding)
        #expect(stores.app.request(.addSkill(query: nil)))
    }

    // MARK: - Sidebar hint

    @Test func sidebarHintShowsUntilTheFirstProjectIsAdded() async {
        let stores = Boot.fixtures(selecting: .personal, selection: nil)
        stores.settings.recentProjects = []
        #expect(SidebarHint.isShown(projects: stores.app.projects))
        stores.app.open(folder: URL(fileURLWithPath: "/tmp/first-project"))
        #expect(!SidebarHint.isShown(projects: stores.app.projects))
    }

    // MARK: - Copy

    @Test func brewCommandsAreTheReleasedFormula() {
        #expect(OnboardingCopy.installCommand == "brew install getresponse/tap/skillcask")
        #expect(OnboardingCopy.upgradeCommand == "brew upgrade getresponse/tap/skillcask")
    }

    @Test func foundAndNeededRows() {
        #expect(
            OnboardingCopy.foundValue(Version(0, 7, 2), at: "/opt/homebrew/bin/skillcask")
                == "0.7.2 at /opt/homebrew/bin/skillcask")
        #expect(OnboardingCopy.foundValue(Version(0, 7, 2), at: nil) == "0.7.2")
        #expect(OnboardingCopy.neededValue(Capabilities.minimum) == "0.9.4 or newer")
    }

    @Test func learnMoreOpensThePublicReadme() {
        #expect(OnboardingCopy.readme.absoluteString == "https://github.com/GetResponse/skillcask")
        #expect(OnboardingCopy.installSection.absoluteString == "https://github.com/GetResponse/skillcask#install")
    }
}
