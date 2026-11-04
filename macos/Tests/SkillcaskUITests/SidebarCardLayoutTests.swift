import AppKit
import SkillcaskCore
import SkillcaskUpdates
import SwiftUI
import Testing

@testable import SkillcaskUI

/// U1's app-update card sits in the sidebar's bottom inset, outside the `List`. On macOS 26 and later (observed on
/// macOS 27) the `NavigationSplitView` sizes its split view from the sidebar's ideal height, and a wrapping `Text` with
/// a vertical `fixedSize` there reports a huge one: after either Copy button of the update sheet (the card turns to
/// "Waiting for the update") the columns were laid out 1220 pt tall in a 726 pt window, centred, so they started
/// 221 pt above it; the consent prompt at first launch made them 1844 pt tall. The real `MainWindow`, in an on-screen
/// window of the reporter's size: the split view must fill the window, and the card's lines must still wrap in full.
@Suite(.serialized) @MainActor struct SidebarCardLayoutTests {
    static let installed = Version(0, 10, 3)
    static let latest = Version(0, 10, 5)

    @Test(.timeLimit(.minutes(1)), arguments: [AppUpdateStore.SheetAction.copyCommand, .copyAndOpenTerminal])
    func copyingTheCommandKeepsTheColumnsInTheWindow(action: AppUpdateStore.SheetAction) throws {
        let updates = Self.updates(UpdateState(consent: .declined, latestSeen: Self.latest))
        let window = Self.window(updates: updates)
        defer { window.close() }
        #expect(updates.card == .available(Self.latest))

        updates.presentSheet(for: Self.latest)
        Self.settle(1.0)
        updates.perform(action, on: Self.latest)
        Self.settle(1.5)

        #expect(updates.card == .awaitingRelaunch)
        let split = try Self.expectColumnsFill(window)
        let words = try Self.sidebarText(split)
        #expect(words.contains(AppUpdateCopy.awaitingTitle), "the sidebar reads: \(words)")
        #expect(words.contains("reopen Skillcask."), "the card's last line is cut: \(words)")
    }

    @Test(.timeLimit(.minutes(1))) func theConsentPromptKeepsTheColumnsInTheWindow() throws {
        let updates = Self.updates(UpdateState(consent: .undecided))
        let window = Self.window(updates: updates)
        defer { window.close() }

        #expect(updates.card == .consentPrompt)
        let split = try Self.expectColumnsFill(window)
        let words = try Self.sidebarText(split)
        #expect(words.contains(AppUpdateCopy.consentTitle), "the sidebar reads: \(words)")
        #expect(words.contains("skill information."), "the card's last line is cut: \(words)")
    }

    // MARK: - Helpers

    /// The split view, in the window's content view, starts at its top and ends at its bottom: a split view taller
    /// than the window is centred and overflows both edges.
    @discardableResult static func expectColumnsFill(
        _ window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> NSSplitView {
        let content = try #require(window.contentView, sourceLocation: sourceLocation)
        let split = try #require(splitViews(in: content).first, sourceLocation: sourceLocation)
        let frame = split.convert(split.bounds, to: content)
        #expect(
            frame.minY >= 0 && frame.maxY <= content.bounds.height,
            "the split view spans \(frame.minY)…\(frame.maxY) pt in a \(content.bounds.height) pt window",
            sourceLocation: sourceLocation)
        return split
    }

    /// The words OCR reads in the sidebar column, joined by spaces.
    static func sidebarText(_ split: NSSplitView) throws -> String {
        let sidebar = try #require(split.arrangedSubviews.first)
        return ActivityDrawerHostTests.texts(in: sidebar).joined(separator: " ")
    }

    static func splitViews(in view: NSView) -> [NSSplitView] {
        (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews(in:))
    }

    static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// An update store on in-memory defaults whose system actions do nothing and whose check never runs.
    static func updates(_ state: UpdateState) -> AppUpdateStore {
        AppUpdateStore(
            installed: installed, installMethod: .homebrew, defaults: UpdateDefaults(MemoryDefaults.make()),
            state: state,
            system: AppUpdateStore.System(copy: { _ in }, open: { _ in }, openApplication: { _ in }, reveal: { _ in }),
            now: { Date() }, sleep: { _ in throw CancellationError() },
            context: {
                .init(
                    client: FakeCLIClient(),
                    binary: .bundled(URL(fileURLWithPath: "/Applications/Skillcask.app/Contents/Helpers/skillcask")),
                    capabilities: Capabilities(version: installed))
            })
    }

    /// `MainWindow` on the fixtures in a titled, unified-toolbar window of the reporter's size (1315 × 726), shown
    /// and settled. The caller closes it.
    static func window(updates: AppUpdateStore) -> NSWindow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let stores = Boot.fixtures()
        let root = MainWindow()
            .skillcaskEnvironment(
                app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client,
                updates: updates)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setFrame(NSRect(x: 131, y: 125, width: 1315, height: 726), display: true)
        // Closed by the test, released by ARC: AppKit's release on close would free it a second time.
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settle(1.5)
        return window
    }
}
