import AppKit
import Foundation
import SkillcaskCore
import SwiftUI
import Testing

@testable import SkillcaskUI

/// The resizable Add Skill sheet's sizes: where it opens (`SheetSizing`), what is remembered (`SettingsStore`) and
/// how the results column grows (`ResultsColumn.width(in:)`).
@Suite struct SheetSizingTests {
    static let min = Size.addSkillSheet
    static let cap = Size.addSkillSheetMax
    static let laptop = CGSize(width: 1470, height: 919)
    static let display = CGSize(width: 2560, height: 1415)

    @Test func nothingSavedAndNoWindowOpensAtTheMinimum() {
        #expect(SheetSizing.ideal(saved: nil, window: nil, screen: nil, min: Self.min, max: Self.cap) == Self.min)
    }

    @Test func nothingSavedOpensAMarginInsideTheWindow() {
        let ideal = SheetSizing.ideal(
            saved: nil, window: CGSize(width: 1315, height: 698), screen: Self.display, min: Self.min, max: Self.cap)
        #expect(ideal == CGSize(width: 1235, height: 660))
        let big = SheetSizing.ideal(
            saved: nil, window: CGSize(width: 1300.5, height: 900.5), screen: Self.display, min: Self.min,
            max: Self.cap)
        #expect(big == CGSize(width: 1220, height: 820))
    }

    @Test func aSmallWindowStillOpensAtTheMinimum() {
        let ideal = SheetSizing.ideal(
            saved: nil, window: CGSize(width: 960, height: 600), screen: Self.laptop, min: Self.min, max: Self.cap)
        #expect(ideal == Self.min)
    }

    @Test func aHugeWindowStopsAtTheCapAndTheScreen() {
        let window = CGSize(width: 2560, height: 1380)
        #expect(
            SheetSizing.ideal(saved: nil, window: window, screen: Self.display, min: Self.min, max: Self.cap)
                == Self.cap)
        let onLaptop = SheetSizing.ideal(
            saved: nil, window: window, screen: Self.laptop, min: Self.min, max: Self.cap)
        #expect(onLaptop == CGSize(width: 1470, height: 919))
    }

    @Test func aSavedSizeWinsOverTheWindow() {
        let ideal = SheetSizing.ideal(
            saved: CGSize(width: 1000, height: 700), window: CGSize(width: 1800, height: 1100), screen: Self.display,
            min: Self.min, max: Self.cap)
        #expect(ideal == CGSize(width: 1000, height: 700))
    }

    @Test func aSavedSizeBelowTheMinimumGrowsToIt() {
        let ideal = SheetSizing.ideal(
            saved: CGSize(width: 400, height: 900), window: nil, screen: Self.display, min: Self.min, max: Self.cap)
        #expect(ideal == CGSize(width: 900, height: 900))
    }

    /// A size saved on a big display opens within a laptop's screen.
    @Test func aSavedSizeAboveTheScreenShrinksToIt() {
        let ideal = SheetSizing.ideal(
            saved: CGSize(width: 1600, height: 1100), window: nil, screen: Self.laptop, min: Self.min, max: Self.cap)
        #expect(ideal == CGSize(width: 1470, height: 919))
    }

    @Test(arguments: [
        CGSize(width: -1, height: 700), CGSize(width: 0, height: 0), CGSize(width: CGFloat.nan, height: 700),
        CGSize(width: 1000, height: CGFloat.infinity),
    ])
    func aCorruptSavedSizeIsIgnored(saved: CGSize) {
        let ideal = SheetSizing.ideal(
            saved: saved, window: CGSize(width: 1180, height: 820), screen: Self.display, min: Self.min, max: Self.cap)
        #expect(ideal == CGSize(width: 1100, height: 740))
    }

    /// The height opens no taller than the room below the window's content top, but never below the minimum.
    @Test func theRoomBelowTheWindowCapsTheHeight() {
        let saved = CGSize(width: 1400, height: 1000)
        let ideal = SheetSizing.ideal(
            saved: saved, window: nil, screen: Self.display, room: 760.5, min: Self.min, max: Self.cap)
        #expect(ideal == CGSize(width: 1400, height: 760))
        let cramped = SheetSizing.ideal(
            saved: saved, window: nil, screen: Self.display, room: 400, min: Self.min, max: Self.cap)
        #expect(cramped == CGSize(width: 1400, height: 660))
        for room in [CGFloat.nan, -10, 0] {
            let ignored = SheetSizing.ideal(
                saved: saved, window: nil, screen: Self.display, room: room, min: Self.min, max: Self.cap)
            #expect(ignored == saved, "\(room)")
        }
    }

    /// A resize that ends at the minimum (within 1 pt per axis) forgets the size; anything else is kept.
    @Test func aResizeBackToTheMinimumForgetsTheSize() {
        #expect(SheetSizing.remembered(Self.min, min: Self.min) == nil)
        #expect(SheetSizing.remembered(CGSize(width: 900.5, height: 661), min: Self.min) == nil)
        #expect(
            SheetSizing.remembered(CGSize(width: 902, height: 660), min: Self.min) == CGSize(width: 902, height: 660))
        #expect(
            SheetSizing.remembered(CGSize(width: 900, height: 700), min: Self.min) == CGSize(width: 900, height: 700))
        #expect(SheetSizing.remembered(CGSize(width: CGFloat.nan, height: 700), min: Self.min) == nil)
    }

    /// A screen smaller than the minimum never caps the sheet below it: AppKit clamps a sheet to the screen.
    @Test func theMaximumIsNeverBelowTheMinimum() {
        #expect(SheetSizing.maximum(cap: Self.cap, screen: CGSize(width: 800, height: 600), min: Self.min) == Self.min)
        #expect(SheetSizing.maximum(cap: Self.cap, screen: Self.laptop, min: Self.min) == Self.laptop)
        #expect(SheetSizing.maximum(cap: Self.cap, screen: nil, min: Self.min) == Self.cap)
        #expect(Self.cap.width > Self.min.width && Self.cap.height > Self.min.height)
    }

    @Test func theResultsColumnKeepsTheBoardWidthThenGrowsToItsCap() {
        #expect(ResultsColumn.width(in: 900) == 440)
        #expect(ResultsColumn.width(in: 1100) == 440)
        #expect(ResultsColumn.width(in: 1200) == 480)
        #expect(ResultsColumn.width(in: 1201) == 480)
        #expect(ResultsColumn.width(in: 1300) == 520)
        #expect(ResultsColumn.width(in: 1600) == 520)
    }
}

/// `SettingsStore.addSkillSheetSize` over in-memory defaults: written as `[width, height]`, read back, and anything
/// else read as nil.
@Suite @MainActor struct AddSkillSheetSizeSettingsTests {
    @Test func theSizeRoundTrips() {
        let defaults = MemoryDefaults.make()
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.addSkillSheetSize == nil)
        settings.addSkillSheetSize = CGSize(width: 1234, height: 876)
        #expect(defaults.values[SettingsStore.Key.addSkillSheetSize] as? [Double] == [1234, 876])
        #expect(SettingsStore(defaults: defaults).addSkillSheetSize == CGSize(width: 1234, height: 876))
        settings.addSkillSheetSize = nil
        #expect(SettingsStore(defaults: defaults).addSkillSheetSize == nil)
    }

    @Test func aCorruptValueReadsAsNil() {
        let stored: [Any] = [
            "1200x800", [1200.0], [1200.0, 800.0, 1.0], [-5.0, 800.0], ["a", "b"], [Double.nan, 800.0],
        ]
        for value in stored {
            let defaults = MemoryDefaults.make()
            defaults.set(value, forKey: SettingsStore.Key.addSkillSheetSize)
            #expect(SettingsStore(defaults: defaults).addSkillSheetSize == nil, "\(value)")
        }
    }
}

/// The sheet as AppKit lays it out: its minimum is the board size, a larger size fills it with the results column at
/// most 520 pt, and presented from a window it is a resizable sheet that keeps the size it is given.
@Suite(.serialized) @MainActor struct AddSkillSheetLayoutTests {
    static let scope = Scope.project(URL(fileURLWithPath: "/tmp/add-skill-size"))

    static func sheet(
        ideal: CGSize = Size.addSkillSheet, runner: ActionRunner = ActionRunner(queue: MutationQueue())
    ) -> some View {
        let store = ScopeStore(
            scope: scope, client: FakeCLIClient(), capabilities: Capabilities(version: Capabilities.minimum)
        ) { _ in SkillText.parse("") }
        return AddSkillSheet(search: SearchStore(store: store), ideal: ideal).environment(runner)
    }

    @Test func theMinimumIsTheBoardSizeAndTheIdealIsTheOneGiven() {
        _ = NSApplication.shared
        let minimum = NSHostingController(rootView: Self.sheet()).sizeThatFits(in: .zero)
        #expect(minimum == Size.addSkillSheet)
        let ideal = CGSize(width: 1180, height: 790)
        let host = NSHostingView(rootView: Self.sheet(ideal: ideal))
        #expect(host.fittingSize == ideal)
        let maximum = NSHostingController(rootView: Self.sheet())
            .sizeThatFits(in: CGSize(width: 5000, height: 5000))
        #expect(maximum == Size.addSkillSheetMax)
    }

    /// The body's three columns at 1400 pt: the results at their 520 pt cap, the hairline, the preview to the edge.
    @Test func aWideSheetGivesTheRestToThePreview() {
        _ = NSApplication.shared
        let frames = FrameBox()
        let size = CGSize(width: 1400, height: 900)
        let host = NSHostingView(
            rootView: AddSkillColumns {
                Color.red.onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames.column = $0
                }
                Color.gray.onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames.rule = $0
                }
                Color.blue.onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frames.preview = $0
                }
            }
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Closed here, released by ARC: AppKit's release on close would free it a second time.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        ActivityDrawerHostTests.settle(window, host)
        #expect(frames.column == CGRect(x: 0, y: 0, width: 520, height: 900))
        #expect(frames.rule == CGRect(x: 520, y: 0, width: 1, height: 900))
        #expect(frames.preview == CGRect(x: 521, y: 0, width: 879, height: 900))
    }

    /// The whole sheet at 1400 × 900 takes that size (nothing in it holds it at the board size).
    @Test func theSheetFillsALargerSize() {
        _ = NSApplication.shared
        let size = CGSize(width: 1400, height: 900)
        let box = FrameBox()
        let host = NSHostingView(
            rootView: Self.sheet()
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    box.column = $0
                })
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer { window.close() }
        ActivityDrawerHostTests.settle(window, host)
        #expect(box.column?.size == size)
    }

    /// `SheetHost`'s Add Skill sheet presented from a titled window: AppKit makes the sheet window resizable (its
    /// minimum and maximum differ), opens it a margin inside the window, keeps a larger frame it is given, and
    /// leaves the parent window's size alone. The size a live resize ends at is remembered; one ending at the
    /// minimum forgets it.
    @Test(.timeLimit(.minutes(1))) func thePresentedSheetIsResizable() async throws {
        let presented = try await Presented.open()
        defer { presented.close() }
        let (window, sheet, settings) = (presented.window, presented.sheet, presented.settings)
        #expect(sheet.contentMinSize.width >= Size.addSkillSheet.width)
        #expect(sheet.contentMinSize.height >= Size.addSkillSheet.height)
        #expect(sheet.contentMaxSize != sheet.contentMinSize, "min \(sheet.contentMinSize) max \(sheet.contentMaxSize)")
        let visible = try #require((window.screen ?? NSScreen.main)?.visibleFrame)
        let room = window.convertToScreen(window.contentLayoutRect).maxY - visible.minY
        let ideal = SheetSizing.ideal(
            saved: nil, window: window.contentLayoutRect.size, screen: visible.size, room: room,
            min: Size.addSkillSheet, max: Size.addSkillSheetMax)
        let opened = sheet.contentRect(forFrameRect: sheet.frame).size
        #expect(opened == ideal, "opened at \(opened)")
        let parentFrame = window.frame

        // A size inside the cap, the screen and the room: larger where it fits, else smaller, never the minimum.
        let upper = SheetSizing.maximum(cap: Size.addSkillSheetMax, screen: visible.size, min: Size.addSkillSheet)
        let target = CGSize(
            width: Self.nudge(opened.width, by: 120, within: Size.addSkillSheet.width...upper.width),
            height: Self.nudge(
                opened.height, by: 60,
                within: Size.addSkillSheet.height...max(Size.addSkillSheet.height, min(upper.height, room))))
        try await presented.liveResize(to: target)
        #expect(sheet.contentRect(forFrameRect: sheet.frame).size == target, "the sheet went to \(sheet.frame.size)")
        #expect(window.frame == parentFrame)
        let saved = await Self.waitFor { settings.addSkillSheetSize }
        #expect(saved == target)

        try await presented.liveResize(to: Size.addSkillSheet)
        let forgotten = await Self.waitFor { settings.addSkillSheetSize == nil ? true : nil }
        #expect(forgotten == true, "still remembers \(String(describing: settings.addSkillSheetSize))")
    }

    /// A sheet nobody resized writes nothing, however long it stays open and when it closes: the size it opens at
    /// (after SwiftUI's first layout at the minimum) is not a choice. An oversized remembered size stays as written.
    @Test(.timeLimit(.minutes(1)), arguments: [CGSize?.none, CGSize(width: 5000, height: 4000)])
    func anUntouchedSheetRemembersNothing(saved: CGSize?) async throws {
        let presented = try await Presented.open(saved: saved)
        defer { presented.close() }
        // Well past any settling the sheet does when it opens.
        for _ in 0..<20 {
            Self.turn(0.02)
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(presented.settings.addSkillSheetSize == saved)
        presented.shown.isShown = false
        let closed = await Self.waitFor { presented.window.attachedSheet == nil ? true : nil }
        #expect(closed == true)
        for _ in 0..<5 {
            Self.turn(0.02)
            try await Task.sleep(for: .milliseconds(50))
        }
        presented.close()
        #expect(presented.settings.addSkillSheetSize == saved)
    }

    /// `value` moved by `delta` when that stays in `range`, else moved back by it, clamped to the range and kept off
    /// its lower end (the minimum, which a resize forgets).
    static func nudge(_ value: CGFloat, by delta: CGFloat, within range: ClosedRange<CGFloat>) -> CGFloat {
        let moved = value + delta <= range.upperBound ? value + delta : value - delta
        let clamped = min(range.upperBound, max(range.lowerBound, moved))
        return clamped == range.lowerBound ? min(range.upperBound, clamped + 1 + SheetSizing.minimumTolerance) : clamped
    }

    static func turn(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// Run-loop turns and main-actor yields (SwiftUI's presentation and the size's write run as main-actor work a
    /// synchronous run-loop turn does not reach) until `probe` answers, at most 5 s.
    static func waitFor<T>(_ probe: () -> T?) async -> T? {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let value = probe() { return value }
            turn(0.02)
            try? await Task.sleep(for: .milliseconds(30))
        }
        return probe()
    }

    /// The sheet presented from its own titled window, which is passed to `SheetHost` as the presenter, so no other
    /// suite's window is ever read.
    @MainActor final class Presented {
        let window: NSWindow
        let sheet: NSWindow
        let settings: SettingsStore
        let shown: ShownBox
        private let policy: NSApplication.ActivationPolicy
        private var closed = false

        private init(
            window: NSWindow, sheet: NSWindow, settings: SettingsStore, shown: ShownBox,
            policy: NSApplication.ActivationPolicy
        ) {
            self.window = window
            self.sheet = sheet
            self.settings = settings
            self.shown = shown
            self.policy = policy
        }

        static func open(saved: CGSize? = nil) async throws -> Presented {
            _ = NSApplication.shared
            let policy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.accessory)
            let defaults = MemoryDefaults.make()
            let settings = SettingsStore(defaults: defaults)
            settings.addSkillSheetSize = saved
            let runner = ActionRunner(queue: MutationQueue())
            let store = ScopeStore(
                scope: AddSkillSheetLayoutTests.scope, client: FakeCLIClient(),
                capabilities: Capabilities(version: Capabilities.minimum)
            ) { _ in SkillText.parse("") }
            let shown = ShownBox()
            let presenter = WindowRef()
            let root = Presenter(shown: shown) {
                SheetHost(sheet: .addSkill(query: nil), store: store, presenter: presenter, onClose: {})
            }
            .environment(settings)
            .environment(runner)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.styleMask = [.titled, .closable, .resizable]
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            // 1300 × 900 at most, inside the screen, so the sheet has room below the window's content top.
            let size = CGSize(width: min(1300, visible.width), height: min(900, visible.height))
            window.setFrame(
                NSRect(x: visible.minX, y: visible.maxY - size.height, width: size.width, height: size.height),
                display: true)
            window.isReleasedWhenClosed = false
            presenter.window = window
            window.makeKeyAndOrderFront(nil)
            shown.isShown = true
            guard let sheet = await AddSkillSheetLayoutTests.waitFor({ window.attachedSheet }) else {
                window.close()
                NSApp.setActivationPolicy(policy)
                throw PresentError()
            }
            for _ in 0..<5 {
                AddSkillSheetLayoutTests.turn(0.02)
                try await Task.sleep(for: .milliseconds(30))
            }
            return Presented(window: window, sheet: sheet, settings: settings, shown: shown, policy: policy)
        }

        /// Resizes the sheet's content to `size`, top edge fixed, between the live-resize notifications a drag posts.
        func liveResize(to size: CGSize) async throws {
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: sheet)
            var frame = sheet.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = CGPoint(x: sheet.frame.minX, y: sheet.frame.maxY - frame.height)
            sheet.setFrame(frame, display: true)
            for _ in 0..<5 {
                AddSkillSheetLayoutTests.turn(0.02)
                try await Task.sleep(for: .milliseconds(30))
            }
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: sheet)
        }

        func close() {
            guard !closed else { return }
            closed = true
            if window.attachedSheet != nil {
                window.endSheet(sheet)
            }
            window.close()
            NSApp.setActivationPolicy(policy)
        }

        struct PresentError: Error {}
    }

    @MainActor final class FrameBox {
        var column: CGRect?
        var rule: CGRect?
        var preview: CGRect?
    }

    @MainActor @Observable final class ShownBox {
        var isShown = false
    }

    struct Presenter<Content: View>: View {
        @Bindable var shown: ShownBox
        @ViewBuilder let content: () -> Content

        var body: some View {
            Color.clear.frame(minWidth: 400, minHeight: 300).sheet(isPresented: $shown.isShown, content: content)
        }
    }
}
