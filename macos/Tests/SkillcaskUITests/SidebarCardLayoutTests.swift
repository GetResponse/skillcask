import AppKit
import SkillcaskCore
import SkillcaskUpdates
import SwiftUI
import Testing

@testable import SkillcaskUI

/// U1's app-update card sits in the sidebar's bottom inset, outside the `List`. A vertical `fixedSize` on its
/// wrapping text makes the text's ideal height its minimum height, and the `NavigationSplitView` forces that
/// minimum, measured narrow, onto the split view (observed on macOS 27): after either Copy button of the update
/// sheet (the card turns to "Waiting for the update") the columns were laid out 1220 pt tall in a 726 pt window,
/// centred, so they started 221 pt above it; the consent prompt at first launch made them 1844 pt tall. The real
/// `MainWindow`, in an on-screen window of the reporter's size: the split view must fill the window.
@Suite(.serialized) @MainActor struct SidebarCardLayoutTests {
    static let installed = Version(0, 10, 3)
    static let latest = Version(0, 10, 5)

    @Test(.timeLimit(.minutes(1)), arguments: [AppUpdateStore.SheetAction.copyCommand, .copyAndOpenTerminal])
    func copyingTheCommandKeepsTheColumnsInTheWindow(action: AppUpdateStore.SheetAction) throws {
        let updates = Self.updates(UpdateState(consent: .declined, latestSeen: Self.latest))
        try Self.withMainWindow(updates: updates) { window in
            #expect(updates.card == .available(Self.latest))
            updates.presentSheet(for: Self.latest)
            try Self.settle(window)
            updates.perform(action, on: Self.latest)
            try Self.settle(window)

            #expect(updates.card == .awaitingRelaunch)
            try Self.expectColumnsFill(window)
        }
    }

    @Test(.timeLimit(.minutes(1))) func theConsentPromptKeepsTheColumnsInTheWindow() throws {
        let updates = Self.updates(UpdateState(consent: .undecided))
        try Self.withMainWindow(updates: updates) { window in
            #expect(updates.card == .consentPrompt)
            try Self.expectColumnsFill(window)
        }
    }

    // MARK: - Helpers

    /// The split view, in the window's content view, starts at its top and ends at its bottom: a split view taller
    /// than the window is centred and overflows both edges.
    static func expectColumnsFill(_ window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let content = try #require(window.contentView, sourceLocation: sourceLocation)
        let frame = try splitFrame(window, sourceLocation: sourceLocation)
        #expect(
            frame.minY >= 0 && frame.maxY <= content.bounds.height,
            "the split view spans \(frame.minY)…\(frame.maxY) pt in a \(content.bounds.height) pt window",
            sourceLocation: sourceLocation)
    }

    /// The `NSSplitView`'s frame in the window's content view.
    static func splitFrame(_ window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation) throws -> NSRect {
        let content = try #require(window.contentView, sourceLocation: sourceLocation)
        let split = try #require(splitViews(in: content).first, sourceLocation: sourceLocation)
        return split.convert(split.bounds, to: content)
    }

    static func splitViews(in view: NSView) -> [NSSplitView] {
        (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews(in:))
    }

    /// Run-loop turns and layout until the split view's frame has held for five turns in a row, at most 3 s.
    static func settle(_ window: NSWindow) throws {
        var last: NSRect?
        var steady = 0
        let deadline = Date(timeIntervalSinceNow: 3)
        while steady < 5, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            let frame = try? splitFrame(window)
            steady = frame != nil && frame == last ? steady + 1 : 0
            last = frame
        }
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
    /// and settled, for `body`; then the window closes and the activation policy is restored.
    static func withMainWindow(updates: AppUpdateStore, _ body: (NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(policy) }
        let stores = Boot.fixtures()
        let root = MainWindow()
            .skillcaskEnvironment(
                app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client,
                updates: updates)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setFrame(NSRect(x: 131, y: 125, width: 1315, height: 726), display: true)
        // Closed here, released by ARC: AppKit's release on close would free it a second time.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // On screen: the split view is laid out from the sidebar's height only once the window is visible.
        window.makeKeyAndOrderFront(nil)
        try settle(window)
        try body(window)
    }
}

/// U1's card alone, as the sidebar footer offers it its ideal height (`AppUpdateCardSlot` in a `safeAreaInset`), at
/// the sidebar's ideal and minimum widths, drawn offscreen and read back: without a vertical `fixedSize` the title
/// and body still wrap in full, not truncated.
@Suite(.serialized) @MainActor struct AppUpdateCardTextTests {
    static let installed = Version(0, 10, 3)

    @Test(arguments: [Size.sidebarWidth, Size.sidebarMinWidth]) func theWaitingCardReadsInFull(width: CGFloat) {
        let words = Self.words(.awaitingRelaunch, width: width)
        #expect(words.text.contains(AppUpdateCopy.awaitingTitle), "\(words.place) reads: \(words.text)")
        #expect(words.text.contains("reopen Skillcask."), "\(words.place), the last line is cut: \(words.text)")
    }

    @Test(arguments: [Size.sidebarWidth, Size.sidebarMinWidth]) func theConsentPromptReadsInFull(width: CGFloat) {
        let words = Self.words(.consentPrompt, width: width)
        #expect(words.text.contains(AppUpdateCopy.consentTitle), "\(words.place) reads: \(words.text)")
        #expect(words.text.contains("skill information."), "\(words.place), the last line is cut: \(words.text)")
    }

    /// The card padded as the slot pads it, in a hosting view of its fitting size (the width given, the ideal
    /// height), in a borderless offscreen window; the OCR'd lines joined by spaces, and where they were read.
    static func words(_ card: UpdateCard, width: CGFloat) -> (text: String, place: String) {
        _ = NSApplication.shared
        let host = NSHostingView(
            rootView: AppUpdateCard(card: card, installed: installed)
                .padding(.horizontal, AppUpdateCard.padding)
                .frame(width: width)
                .background(Color.surfaceSidebar))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Closed here, released by ARC: AppKit's release on close would free it a second time.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        ActivityDrawerHostTests.settle(window, host)
        let text = ActivityDrawerHostTests.texts(in: host).joined(separator: " ")
        return (text, "\(type(of: host)) at \(host.frame)")
    }
}
