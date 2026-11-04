import Foundation
import SkillcaskCore
import SkillcaskUpdates
import SwiftUI

extension PreviewRegistry {
    /// U1, the app-update card (D51): `available`, `consent` and `awaiting` alone at the sidebar's 220 pt on its
    /// ground, and `window`, the whole window over the fixture boot with the available card above Open Folder….
    /// U2/U3, the update sheet: `homebrew`, `direct`, `translocated` (original unknown, the live case) and
    /// `translocatedOriginal`. U5, Settings › Updates: `available` (Homebrew, daily on, checked a minute ago),
    /// `skipped` (a download, daily off, 0.10.3 skipped) and `never` (undecided, the CLI not ready: Check Now
    /// disabled with its reason). Versions are data: the app at 0.10.2, 0.10.3 released.
    static let appUpdate: [Entry] = [
        card("available", height: 104, .available(AppUpdateSample.latest)),
        card("consent", height: 140, .consentPrompt),
        card("awaiting", height: 84, .awaitingRelaunch),
        Entry(id: "U1", state: "window", size: CGSize(width: 1280, height: 800)) {
            AnyView(AppUpdateWindowSample())
        },
        sheet("U2", "homebrew", height: 304, .homebrew),
        sheet("U3", "direct", height: 270, .direct),
        sheet("U3", "translocated", height: 330, .translocated(original: nil)),
        sheet("U3", "translocatedOriginal", height: 380, .translocated(original: AppUpdateSample.original)),
        settings("available", height: 570) {
            UpdateState(
                consent: .granted, lastCheckAt: Date().addingTimeInterval(-60), latestSeen: AppUpdateSample.latest)
        },
        settings("skipped", height: 570, method: .direct) {
            UpdateState(
                consent: .declined, lastCheckAt: Date().addingTimeInterval(-26 * 3600),
                latestSeen: AppUpdateSample.latest, skippedVersion: AppUpdateSample.latest)
        },
        settings("never", height: 600, ready: false) { UpdateState() },
    ]

    /// U2/U3: the update sheet on 0.10.3 for one install method, alone at its width.
    private static func sheet(_ id: String, _ state: String, height: CGFloat, _ method: InstallMethod) -> Entry {
        Entry(id: id, state: state, size: CGSize(width: AppUpdateSheet.width, height: height)) {
            AnyView(
                AppUpdateSheet(version: AppUpdateSample.latest, installed: AppUpdateSample.installed)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.surfaceWindow)
                    .environment(
                        AppUpdateSample.store(
                            method: method, state: UpdateState(consent: .granted, latestSeen: AppUpdateSample.latest))
                    ))
        }
    }

    /// U5: Settings › Updates with the `Skillcask app` group over the fixture stores (signed out of GitHub).
    private static func settings(
        _ state: String, height: CGFloat, method: InstallMethod = .homebrew, ready: Bool = true,
        _ make: @escaping @MainActor @Sendable () -> UpdateState
    ) -> Entry {
        Entry(id: "U5", state: state, size: CGSize(width: Size.settingsWidth, height: height)) {
            AnyView(AppUpdateSettingsSample(method: method, state: make(), ready: ready))
        }
    }

    private static func card(_ state: String, height: CGFloat, _ card: UpdateCard) -> Entry {
        Entry(id: "U1", state: state, size: CGSize(width: Size.sidebarWidth, height: height)) {
            AnyView(
                AppUpdateCard(card: card, installed: AppUpdateSample.installed)
                    // The sidebar footer offers the card its ideal height; a fixed-height entry would not.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(AppUpdateCard.padding)
                    .frame(width: Size.sidebarWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.surfaceSidebar))
        }
    }
}

/// The versions the U1 renders show.
enum AppUpdateSample {
    static let installed = Version(0, 10, 2)
    static let latest = Version(0, 10, 3)
    /// Where a translocated copy came from, when the system tells.
    static let original = URL(fileURLWithPath: "/Users/me/Downloads/Skillcask.app")

    /// A store that starts from `state` with no CLI (or the bundled one when `ready`), writing nothing: renders click
    /// nothing.
    @MainActor static func store(method: InstallMethod, state: UpdateState, ready: Bool = false) -> AppUpdateStore {
        let client = FixtureCLIClient()
        let binary = Locator.Choice.bundled(
            URL(fileURLWithPath: "/Applications/Skillcask.app/Contents/Helpers/skillcask"))
        return AppUpdateStore(
            installed: installed, installMethod: method,
            defaults: UpdateDefaults(UserDefaults(suiteName: "skillcask.ui.previews.updates") ?? .standard),
            state: state,
            context: {
                ready ? .init(client: client, binary: binary, capabilities: Capabilities(version: installed)) : nil
            })
    }

    /// A store that starts from `consent` and `latestSeen` without reading or writing any defaults (its suite is
    /// never written: the preview mutates nothing), so a render leaves no plist; enabled, asking `app` for the CLI.
    @MainActor static func store(consent: UpdateConsent, latestSeen: Version, app: AppStore) -> AppUpdateStore {
        AppUpdateStore(
            installed: installed,
            defaults: UpdateDefaults(UserDefaults(suiteName: "skillcask.ui.previews.updates") ?? .standard),
            state: UpdateState(consent: consent, latestSeen: latestSeen), context: { [weak app] in app?.updateContext })
    }
}

/// The website scope (healthy, as on the U1 board) with the available card.
private struct AppUpdateWindowSample: View {
    @State private var stores: Boot.Stores
    @State private var updates: AppUpdateStore

    @MainActor init() {
        let stores = Boot.fixtures(selecting: Boot.websiteScope, selection: nil)
        _stores = State(initialValue: stores)
        _updates = State(
            initialValue: AppUpdateSample.store(consent: .declined, latestSeen: AppUpdateSample.latest, app: stores.app)
        )
    }

    var body: some View {
        MainWindow()
            .skillcaskEnvironment(
                app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client,
                updates: updates)
    }
}

/// Settings › Updates with the app group.
private struct AppUpdateSettingsSample: View {
    @State private var stores: Boot.Stores
    @State private var updates: AppUpdateStore

    @MainActor init(method: InstallMethod, state: UpdateState, ready: Bool) {
        let stores = Boot.fixtures()
        stores.settings.checkUpdatesOnOpen = DesignFixtures.settings.checkOnOpen
        stores.app.cliSettings.preload(skillsSh: .on, gitHub: .signedOut)
        _stores = State(initialValue: stores)
        _updates = State(initialValue: AppUpdateSample.store(method: method, state: state, ready: ready))
    }

    var body: some View {
        UpdatesPane()
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.surfaceGrouped)
            .skillcaskEnvironment(
                app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client,
                updates: updates)
    }
}

#Preview("U2 sheet, Homebrew") {
    AppUpdateSheet(version: AppUpdateSample.latest, installed: AppUpdateSample.installed)
        .environment(AppUpdateSample.store(method: .homebrew, state: UpdateState(latestSeen: AppUpdateSample.latest)))
}

#Preview("U1 card, available") {
    AppUpdateCard(card: .available(AppUpdateSample.latest), installed: AppUpdateSample.installed)
        .padding(AppUpdateCard.padding)
        .frame(width: Size.sidebarWidth)
}
