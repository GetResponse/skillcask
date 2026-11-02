import AppKit
import Foundation
import Testing

@testable import SkillcaskUI

/// `SplitViewFrames`: a saved column layout of the main window whose visible columns overlap, or that does not
/// parse, is dropped before the window opens; a sound one, another window's, and every other default are kept.
@Suite struct SplitViewFramesTests {
    private static let key = "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"

    /// A sound layout as AppKit wrote it: sidebar 180, a 1 pt divider, list 415, detail 672.
    private static let sound = [
        "0.000000, 0.000000, 180.000000, 726.000000, NO, NO",
        "181.000000, 0.000000, 415.000000, 726.000000, NO, NO",
        "597.000000, 0.000000, 672.000000, 726.000000, NO, NO",
    ]

    /// The layout from the report, as AppKit saves a sidebar collapsed at quit: flags `NO`, the sidebar's last width,
    /// the list at x 0 under it. The window opened with empty columns and hung, then crashed, on a sidebar toggle.
    private static let overlapping = [
        "0.000000, 0.000000, 228.000000, 1852.000000, NO, NO",
        "0.000000, 0.000000, 613.000000, 1852.000000, NO, NO",
        "614.000000, 0.000000, 784.000000, 1852.000000, NO, NO",
    ]

    @Test func aSoundLayoutIsKept() {
        #expect(SplitViewFrames.unsoundKeys([Self.key: Self.sound]).isEmpty)
    }

    @Test func overlappingColumnsAreDropped() {
        #expect(SplitViewFrames.unsoundKeys([Self.key: Self.overlapping]) == [Self.key])
    }

    @Test func aSidebarCollapsedAtQuitIsDropped() {
        let collapsedAtQuit = [
            "0.000000, 0.000000, 180.000000, 726.000000, NO, NO",
            "0.000000, 0.000000, 415.000000, 726.000000, NO, NO",
            "416.000000, 0.000000, 672.000000, 726.000000, NO, NO",
        ]
        #expect(SplitViewFrames.unsoundKeys([Self.key: collapsedAtQuit]) == [Self.key])
    }

    @Test func aColumnFlaggedCollapsedOrHiddenIsNotCompared() {
        let sidebarCollapsed = [
            "0.000000, 0.000000, 0.000000, 726.000000, YES, NO",
            "0.000000, 0.000000, 415.000000, 726.000000, NO, NO",
            "416.000000, 0.000000, 672.000000, 726.000000, NO, NO",
        ]
        let listHidden = [
            "0.000000, 0.000000, 180.000000, 726.000000, NO, NO",
            "0.000000, 0.000000, 415.000000, 726.000000, NO, YES",
            "181.000000, 0.000000, 672.000000, 726.000000, NO, NO",
        ]
        let sidebarCollapsedKeepingItsWidth = [
            "0.000000, 0.000000, 228.000000, 726.000000, YES, NO",
            "0.000000, 0.000000, 415.000000, 726.000000, NO, NO",
            "416.000000, 0.000000, 672.000000, 726.000000, NO, NO",
        ]
        #expect(SplitViewFrames.unsoundKeys([Self.key: sidebarCollapsed]).isEmpty)
        #expect(SplitViewFrames.unsoundKeys([Self.key: sidebarCollapsedKeepingItsWidth]).isEmpty)
        #expect(SplitViewFrames.unsoundKeys([Self.key: listHidden]).isEmpty)
    }

    @Test func aRightToLeftLayoutIsJudgedTheSameWay() {
        let mirrored = Array(Self.sound.reversed())
        let mirroredOverlapping = Array(Self.overlapping.reversed())
        #expect(SplitViewFrames.unsoundKeys([Self.key: mirrored]).isEmpty)
        #expect(SplitViewFrames.unsoundKeys([Self.key: mirroredOverlapping]) == [Self.key])
    }

    @Test func fractionalFramesThatTouchAreKept() {
        let frames = [
            "0.000000, 0.000000, 180.500000, 726.000000, NO, NO",
            "180.250000, 0.000000, 415.000000, 726.000000, NO, NO",
        ]
        #expect(SplitViewFrames.unsoundKeys([Self.key: frames]).isEmpty)
    }

    @Test func columnsOverlappingByAPointAreDropped() {
        let frames = [
            "0.000000, 0.000000, 180.000000, 726.000000, NO, NO",
            "179.000000, 0.000000, 415.000000, 726.000000, NO, NO",
        ]
        #expect(SplitViewFrames.unsoundKeys([Self.key: frames]) == [Self.key])
    }

    @Test func aLayoutThatDoesNotParseIsDropped() {
        let cases: [Any] = [
            "0, 0, 180, 726, NO, NO",
            ["0.000000, 0.000000, 180.000000, 726.000000, NO"],
            ["0.000000, 0.000000, wide, 726.000000, NO, NO"],
            ["0.000000, 0.000000, -1.000000, 726.000000, NO, NO"],
            ["0.000000, 0.000000, 180.000000, -1.000000, NO, NO"],
            ["0.000000, 0.000000, 180.000000, 726.000000, NO, NO, NO"],
            ["0.000000, 0.000000, 180.000000, 726.000000, MAYBE, NO"],
            ["0.000000, 0.000000, inf, 726.000000, NO, NO"],
            [1, 2, 3],
        ]
        for value in cases {
            #expect(SplitViewFrames.unsoundKeys([Self.key: value]) == [Self.key], "\(value)")
        }
    }

    @Test func otherWindowsAndOtherDefaultsAreLeftAlone() {
        let values: [String: Any] = [
            "NSSplitView Subview Frames SwiftUI.ModifiedContent<Old>-1-AppWindow-1, SidebarNavigationSplitView":
                Self.overlapping,
            "NSSplitView Subview Frames com_apple_SwiftUI_Settings_window, Split": Self.overlapping,
            "NSSplitView Subview Frames mainframe-AppWindow-1, SidebarNavigationSplitView": Self.overlapping,
            "NSWindow Frame main-AppWindow-1": "256 212 1398 809 0 0 1728 1084 ",
            "lastScope": "personal",
        ]
        #expect(SplitViewFrames.unsoundKeys(values).isEmpty)
    }

    @Test func everyMainWindowIsChecked() {
        let second = "NSSplitView Subview Frames main-AppWindow-2, SidebarNavigationSplitView"
        let bare = "NSSplitView Subview Frames main, SidebarNavigationSplitView"
        let values: [String: Any] = [Self.key: Self.sound, second: Self.overlapping, bare: Self.overlapping]
        #expect(SplitViewFrames.unsoundKeys(values) == [bare, second])
    }

    @Test func repairRemovesOnlyTheUnsoundKeysAndReportsThem() {
        let defaults = MemoryDefaults.make()
        let second = "NSSplitView Subview Frames main-AppWindow-2, SidebarNavigationSplitView"
        defaults.set(Self.overlapping, forKey: Self.key)
        defaults.set(Self.sound, forKey: second)
        defaults.set("personal", forKey: "lastScope")
        #expect(SplitViewFrames.repair(defaults) == [Self.key])
        #expect(defaults.object(forKey: Self.key) == nil)
        #expect(defaults.object(forKey: second) != nil)
        #expect(defaults.string(forKey: "lastScope") == "personal")
        #expect(SplitViewFrames.repair(defaults).isEmpty)
    }

    @Test func aLayoutTheAppCannotRemoveIsNotReported() {
        let defaults = MemoryDefaults.make(readOnly: [Self.key: Self.overlapping])
        #expect(SplitViewFrames.repair(defaults).isEmpty)
    }

    /// A main window closing repairs the defaults, so the next one opened in the same process does not restore the
    /// layout it closed with; another window closing (Settings) leaves them alone.
    @MainActor @Test func closingAMainWindowRepairsTheLayoutAgain() {
        let defaults = MemoryDefaults.make()
        let center = NotificationCenter()
        let repairOnClose = SplitViewFrames.RepairOnClose(defaults, center: center)
        defer { withExtendedLifetime(repairOnClose) {} }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defaults.set(Self.overlapping, forKey: Self.key)

        window.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(defaults.object(forKey: Self.key) != nil)

        window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(defaults.object(forKey: Self.key) == nil)
    }

    /// `discardSavedState` against a temporary library and a made-up bundle id, never the user's: it removes that
    /// app's saved state and nothing next to it, and without a bundle id it removes nothing.
    @Test func discardSavedStateRemovesOnlyThisAppsSavedState() throws {
        let library = FileManager.default.temporaryDirectory.appending(
            path: "SplitViewFramesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }
        let states = library.appending(path: "Saved Application State")
        let ours = states.appending(path: "com.example.skillcask-test.savedState")
        let other = states.appending(path: "com.example.other.savedState")
        for folder in [ours, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("state".utf8).write(to: folder.appending(path: "windows.plist"))
        }

        SplitViewFrames.discardSavedState(bundleIdentifier: nil, library: library)
        SplitViewFrames.discardSavedState(bundleIdentifier: "", library: library)
        #expect(FileManager.default.fileExists(atPath: ours.path))

        SplitViewFrames.discardSavedState(bundleIdentifier: "com.example.skillcask-test", library: library)
        #expect(!FileManager.default.fileExists(atPath: ours.path))
        #expect(FileManager.default.fileExists(atPath: other.appending(path: "windows.plist").path))

        // Already gone: nothing to remove, nothing thrown.
        SplitViewFrames.discardSavedState(bundleIdentifier: "com.example.skillcask-test", library: library)
        #expect(FileManager.default.fileExists(atPath: states.path))
    }
}
