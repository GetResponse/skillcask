import Foundation
import SkillcaskCore
import SkillcaskUI
import SwiftUI

/// The entry point: refuses a CLI-style start (`LaunchArguments`), e.g. a `skillcask --version` probe that resolved
/// to this binary, before any SwiftUI or store code runs; otherwise repairs the saved column layout
/// (`SplitViewFrames`) and starts `SkillcaskApp`.
@main
enum Entry {
    static func main() {
        if LaunchArguments.isCLIInvocation(CommandLine.arguments.dropFirst()) {
            FileHandle.standardError.write(Data("Skillcask is the macOS app, not the skillcask CLI.\n".utf8))
            exit(LaunchArguments.refusalStatus)
        }
        if !SplitViewFrames.repair(.standard).isEmpty {
            SplitViewFrames.discardSavedState()
        }
        let repairOnClose = SplitViewFrames.RepairOnClose()
        withExtendedLifetime(repairOnClose) { SkillcaskApp.main() }
    }
}

/// Builds the stores once (`Boot.current()`: the live binary, or the design fixtures when
/// `SKILLCASK_UI_FIXTURES=1`), injects them, and declares the window, the Settings window and the menu bar.
struct SkillcaskApp: App {
    @State private var stores = Boot.current()

    var body: some Scene {
        WindowGroup(id: MainWindow.sceneID) {
            MainWindow()
                .skillcaskEnvironment(
                    app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client,
                    updates: stores.updates)
        }
        .commands { SkillcaskCommands(updates: stores.updates) }
        // S14: the system Settings window, ⌘, from the app menu.
        Settings {
            SettingsView()
                .skillcaskEnvironment(
                    app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client,
                    updates: stores.updates)
        }
    }
}
