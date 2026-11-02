import AppKit
import SkillcaskCore
import UniformTypeIdentifiers

/// The few things the shell asks Finder, Terminal and the open panel for (toolbar ⋯ menu, File and Skill menus).
/// AppKit stays here so views and stores never import it for these.
@MainActor enum Workspace {
    /// `Reveal skills.toml`: selects `manifest` in Finder (from `AppStore.manifest(of:)`, so the personal one is in
    /// the config directory the CLI uses); its folder when the file is missing, `root` when that is missing too.
    static func revealManifest(_ manifest: URL, root: URL) {
        let target =
            [manifest, manifest.deletingLastPathComponent()]
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? root
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// `Reveal in Finder`: selects `url`.
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// A package-controlled folder ("Open folder" on Overview and Contents): selected in Finder, never opened, so a
    /// folder named `x.app` is not launched (`SafeOpen`). A missing folder reveals its nearest existing parent.
    static func revealFolder(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([SafeOpen.revealTarget(folder)])
    }

    /// Contents' `Open in editor`: SKILL.md in the user's default app for plain text, only when `SafeOpen.textFile`
    /// accepts it (a regular plain-text file inside `folder` once symlinks are resolved); otherwise Finder selects
    /// the folder. LaunchServices never picks the handler from the file, so an executable cannot run.
    static func openAsText(_ file: URL, inside folder: URL) {
        guard let target = SafeOpen.textFile(file, inside: folder) else {
            revealFolder(folder)
            return
        }
        let editor =
            NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([target], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    /// `Open in Terminal`: a Terminal window in the scope's root.
    static func openInTerminal(_ scope: Scope) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open(
            [scope.root], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Settings › Advanced, `Open config.toml`: the file in its default app; Finder at its folder when it does not
    /// exist yet (the CLI writes it on the first setting it saves), the nearest existing parent past that.
    static func openOrReveal(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.open(file)
            return
        }
        var folder = file.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: folder.path) && folder.pathComponents.count > 1 {
            folder = folder.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    /// Settings › General, `Choose…`: the system open panel for one file (the command-line tool).
    static func chooseFile(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// `Open Folder…` and `Find Projects in Folder…`: the system open panel for one directory.
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Settings › Advanced "Show Activity", Settings › Updates and Check for Updates…: activates the app and makes
    /// sure a main window is in front, unminimizing it (`mainWindowChoice`). False when there is none, so the caller
    /// opens one.
    static func bringMainWindowForward() -> Bool {
        let windows = NSApp.windows
        let key = NSApp.keyWindow
        let infos = windows.map {
            WindowInfo(
                isMainScene: isMainScene($0.identifier?.rawValue), isKey: $0 === key,
                canBeMain: $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized))
        }
        switch mainWindowChoice(infos) {
        case .keep:
            NSApp.activate()
            return true
        case .raise(let index):
            let window = windows[index]
            NSApp.activate()
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return true
        case .open:
            return false
        }
    }

    /// What `mainWindowChoice` needs of a window: whether the main scene made it, is key, and is on screen or in the
    /// Dock and can be main.
    struct WindowInfo: Equatable {
        var isMainScene: Bool
        var isKey: Bool
        var canBeMain: Bool
    }

    /// Which window shows the main window's answers: `keep` when the key window is already a main window (the menu
    /// is used from it), else the first main window behind (never Settings, which would cover it), else `open` one.
    enum MainWindowChoice: Equatable {
        case keep
        case raise(Int)
        case open
    }

    static func mainWindowChoice(_ windows: [WindowInfo]) -> MainWindowChoice {
        if windows.contains(where: { $0.isKey && $0.isMainScene && $0.canBeMain }) {
            return .keep
        }
        if let index = windows.firstIndex(where: { !$0.isKey && $0.isMainScene && $0.canBeMain }) {
            return .raise(index)
        }
        return .open
    }

    /// SwiftUI names a `WindowGroup`'s windows `<scene id>-AppWindow-<n>`.
    nonisolated static func isMainScene(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == MainWindow.sceneID || identifier.hasPrefix(MainWindow.sceneID + "-")
    }
}
