import AppKit
import SwiftUI

/// The size a resizable sheet opens at, the most it may grow to and what is remembered of it, as pure functions over
/// what the app knows when the sheet opens: the size the user left it at, the presenting window's content size, the
/// screen's visible frame and the room below the window's content top. The Add Skill sheet is the one resizable
/// sheet (`AddSkillSheetHost`).
enum SheetSizing {
    /// How much smaller than the presenting window's content a sheet with no remembered size opens, per axis.
    static let windowMargin: CGFloat = 80
    /// How close to the minimum, per axis, a resize must end for the sheet to forget its size.
    static let minimumTolerance: CGFloat = 1

    /// Two finite, positive numbers: anything else (a corrupt stored value, an unknown window) is ignored.
    static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    /// The largest the sheet may be: `cap`, then the screen per axis, never below `min` (AppKit clamps a sheet
    /// larger than the screen to it).
    static func maximum(cap: CGSize, screen: CGSize?, min: CGSize) -> CGSize {
        let screen = screen.flatMap { isUsable($0) ? $0 : nil }
        return CGSize(
            width: Swift.max(min.width, Swift.min(cap.width, screen?.width ?? cap.width)),
            height: Swift.max(min.height, Swift.min(cap.height, screen?.height ?? cap.height)))
    }

    /// The size the sheet opens at: the remembered size, else the window's content less `windowMargin`, else `min`;
    /// clamped to `min` and to `maximum(cap: max, screen:, min:)`, its height also to `room` (the space from the
    /// window's content top down to the screen's visible bottom, so the footer never opens behind the Dock), and
    /// rounded down to whole points. `min` wins over both: a sheet may overhang at its minimum.
    static func ideal(
        saved: CGSize?, window: CGSize?, screen: CGSize?, room: CGFloat? = nil, min: CGSize, max: CGSize
    ) -> CGSize {
        let upper = maximum(cap: max, screen: screen, min: min)
        let room = room.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? upper.height
        let fromWindow = window.flatMap { isUsable($0) ? $0 : nil }
            .map {
                CGSize(width: $0.width - windowMargin, height: $0.height - windowMargin)
            }
        let base = saved.flatMap { isUsable($0) ? $0 : nil } ?? fromWindow ?? min
        return CGSize(
            width: Swift.min(upper.width, Swift.max(min.width, base.width)).rounded(.down),
            height: Swift.max(min.height, Swift.min(upper.height, room, base.height)).rounded(.down))
    }

    /// What to remember of a sheet the user resized to `size`: nil (back to following the window) when it ends
    /// within `minimumTolerance` of `min` on both axes, else the size.
    static func remembered(_ size: CGSize, min: CGSize) -> CGSize? {
        guard isUsable(size) else { return nil }
        let atMinimum =
            abs(size.width - min.width) <= minimumTolerance && abs(size.height - min.height) <= minimumTolerance
        return atMinimum ? nil : size
    }
}

/// The Add Skill sheet as `SheetHost` presents it: resizable from `Size.addSkillSheet` up to `Size.addSkillSheetMax`
/// and the screen, opening at the size the user last left it at (`SettingsStore.addSkillSheetSize`), else a little
/// smaller than the presenting window. The window, its screen and the remembered size are read once, on the first
/// layout of a presentation (`Opening`); nothing here reads or writes the main window's layout. The size is
/// written only when the user ends a live resize of the sheet, so a sheet nobody resized keeps following the window.
struct AddSkillSheetHost: View {
    let query: String?
    let store: ScopeStore
    /// The window presenting the sheet (`MainWindow`'s own); nil falls back to `Opening.fallbackWindow()`.
    let presenter: WindowRef?
    let onClose: () -> Void

    @Environment(SettingsStore.self) private var settings
    /// What the sheet opens from, read once per presentation.
    @State private var opened = Once<Opening>()

    var body: some View {
        let opening = opened.value {
            Opening.read(from: presenter?.window ?? Opening.fallbackWindow(), saved: settings.addSkillSheetSize)
        }
        AddSkillSheet(
            query: query, store: store, ideal: opening.ideal, maximum: opening.maximum, onClose: onClose
        )
        .background(
            WindowObserver(onLiveResizeEnd: { sheet in
                let size = sheet.contentRect(forFrameRect: sheet.frame).size
                settings.addSkillSheetSize = SheetSizing.remembered(size, min: Size.addSkillSheet)
            })
        )
        .modifier(FittedPresentation())
    }

    /// What the sheet sizes itself from, read from AppKit and the settings when it opens.
    struct Opening {
        var saved: CGSize?
        var window: CGSize?
        var screen: CGSize?
        /// From the window's content top down to its screen's visible bottom.
        var room: CGFloat?

        var ideal: CGSize {
            SheetSizing.ideal(
                saved: saved, window: window, screen: screen, room: room, min: Size.addSkillSheet,
                max: Size.addSkillSheetMax)
        }

        var maximum: CGSize {
            SheetSizing.maximum(cap: Size.addSkillSheetMax, screen: screen, min: Size.addSkillSheet)
        }

        @MainActor static func read(from window: NSWindow?, saved: CGSize?) -> Opening {
            let visible = (window?.screen ?? NSScreen.main)?.visibleFrame
            let contentTop = window.map { $0.convertToScreen($0.contentLayoutRect).maxY }
            return Opening(
                saved: saved, window: window?.contentLayoutRect.size, screen: visible?.size,
                room: visible.flatMap { visible in contentTop.map { $0 - visible.minY } })
        }

        /// The last resort when no presenter is known: the main window (a sheet never becomes main), else the
        /// frontmost visible window that is not a sheet or a panel.
        @MainActor static func fallbackWindow() -> NSWindow? {
            NSApp?.mainWindow
                ?? NSApp?.orderedWindows.first { $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) }
        }
    }
}

/// A value computed on first use and kept: in `@State`, once per view lifetime (a sheet's presentation), without
/// re-running the computation on every init of the view.
@MainActor final class Once<Value> {
    private var stored: Value?

    func value(_ make: () -> Value) -> Value {
        if let stored {
            return stored
        }
        let made = make()
        stored = made
        return made
    }
}

/// A weak reference to a window, filled by `WindowObserver(onWindow:)` and read when a sheet opens.
@MainActor final class WindowRef {
    weak var window: NSWindow?

    init(_ window: NSWindow? = nil) {
        self.window = window
    }
}

/// An empty, click-through AppKit view that reports the window it is in (`onWindow`) and the end of each live resize
/// of that window by the user (`onLiveResizeEnd`; a programmatic `setFrame` has none).
struct WindowObserver: NSViewRepresentable {
    var onWindow: (@MainActor (NSWindow?) -> Void)?
    var onLiveResizeEnd: (@MainActor (NSWindow) -> Void)?

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onWindow = onWindow
        view.onLiveResizeEnd = onLiveResizeEnd
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onWindow = onWindow
        view.onLiveResizeEnd = onLiveResizeEnd
    }

    final class ObserverView: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?
        var onLiveResizeEnd: (@MainActor (NSWindow) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let window {
                NotificationCenter.default.removeObserver(
                    self, name: NSWindow.didEndLiveResizeNotification, object: window)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(didEndLiveResize(_:)), name: NSWindow.didEndLiveResizeNotification,
                    object: window)
            }
            onWindow?(window)
        }

        @objc private func didEndLiveResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, window === self.window else { return }
            onLiveResizeEnd?(window)
        }
    }
}

/// macOS 15 and later size a sheet from its content's ideal and stop letting a flexible frame alone make it
/// resizable once the app is built with that SDK; `.fitted` opts back in. macOS 14 sizes it from the frame.
private struct FittedPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}
