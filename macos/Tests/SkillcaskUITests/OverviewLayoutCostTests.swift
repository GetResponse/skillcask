import AppKit
import Foundation
import SkillcaskCore
import SkillcaskDomain
import SwiftUI
import Testing
import Vision

@testable import SkillcaskUI

/// The Scope Overview of a large project, resized back and forth across `twoColumnMinWidth`: the cards change from
/// one column to two and back. Every row of the Updates, Security and Health cards wraps, so each measurement of a
/// card breaks its lines again, and a measurement at zero width breaks them a letter per line.
@Suite(.serialized) @MainActor struct OverviewLayoutCostTests {
    /// Each card is measured only at a real column width, never at zero, infinite or unspecified width. `CardRows`
    /// measures a card at its column's width; the flexible `HStack` rows it replaced measured each card at zero and
    /// infinite width too to share the row (24 such measurements on each resize into two columns here).
    /// `MeasureProbe`, in `CardContainer`, records the widths in debug builds, so this does not depend on timing.
    @Test(.timeLimit(.minutes(1))) func resizingAcrossTheColumnBreakMeasuresCardsOnlyAtColumnWidths() throws {
        let snapshot = Self.large()
        #expect(UpdatesCard.rows(snapshot).count >= 20)
        #expect(SecurityCard.findings(snapshot).count >= 20)
        try Self.withOverview(snapshot) { window, host in
            for width in [Self.narrow, Self.wide, Self.narrow, Self.wide] {
                MeasureProbe.widths = []
                Self.resize(window, host, width: width)
                let measured = MeasureProbe.widths
                let degenerate = measured.filter { proposed in proposed.map { $0 <= 0 || !$0.isFinite } ?? true }
                #expect(!measured.isEmpty, "no card was measured on the resize to \(width) pt")
                #expect(
                    degenerate.isEmpty,
                    "\(degenerate.count) of \(measured.count) measurements at a degenerate width, resizing to \(width) pt"
                )
            }
        }
    }

    /// The column count changes the cards' places, not the cards: the Health card's passed checks, opened in two
    /// columns, are still open in one and in two again. Two `if` branches built new cards with the disclosure shut.
    @Test(.timeLimit(.minutes(1))) func theCardsKeepTheirStateAcrossTheColumnBreak() throws {
        let snapshot = DesignFixtures.api
        let doctor = try #require(snapshot.doctor)
        let disclosure = OverviewCopy.checksPassed(doctor.passed.count)
        let item = OverviewCopy.passed(try #require(doctor.passedItems.first))
        try Self.withOverview(snapshot) { window, host in
            #expect(!Self.reads(item, in: host))
            let box = try #require(Self.box(of: disclosure, in: host))
            Self.click(window, at: CGPoint(x: box.midX, y: box.midY))
            ActivityDrawerHostTests.settle(window, host)
            #expect(Self.reads(item, in: host), "the disclosure did not open")
            for width in [Self.narrow, Self.wide] {
                Self.resize(window, host, width: width)
                ActivityDrawerHostTests.settle(window, host)
                #expect(Self.reads(item, in: host), "the disclosure is shut at \(width) pt")
            }
        }
    }

    // MARK: - Helpers

    /// Detail widths on both sides of the break: the 960 pt window's 380 pt column and the board's 700.
    static let narrow: CGFloat = 380
    static let wide: CGFloat = 700

    /// The window resized to `width`, laid out at once, and one run-loop turn for what that layout deferred.
    static func resize(_ window: NSWindow, _ host: NSView, width: CGFloat) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: false)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// `ScopeOverviewView` over `snapshot` in a borderless window `wide` × 700, laid out once.
    static func withOverview(_ snapshot: ScopeSnapshot, _ body: (NSWindow, NSView) throws -> Void) throws {
        _ = NSApplication.shared
        let stores = Boot.fixtures(selecting: Boot.apiScope, selection: nil, api: snapshot)
        let store = try #require(stores.app.store(for: Boot.apiScope))
        let host = NSHostingView(
            rootView: ScopeOverviewView(store: store)
                .skillcaskEnvironment(
                    app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client))
        host.frame = NSRect(x: 0, y: 0, width: wide, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // Closed here, released by ARC: AppKit's release on close would free it a second time.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // On screen, without taking focus: an offscreen window gets no click.
        window.orderFrontRegardless()
        ActivityDrawerHostTests.settle(window, host)
        try body(window, host)
    }

    /// The lines OCR reads in `view`, their boxes normalized to it, origin bottom left.
    static func lines(in view: NSView) -> [VNRecognizedText] {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
    }

    /// The box of `text` where OCR first reads it in `view`, in window coordinates (the view fills the window): the
    /// matched characters only, not the whole line, which may hold more than the control.
    static func box(of text: String, in view: NSView) -> CGRect? {
        let size = view.bounds.size
        for line in lines(in: view) {
            guard let range = line.string.range(of: text),
                let box = try? line.boundingBox(for: range)?.boundingBox
            else { continue }
            return CGRect(
                x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width,
                height: box.height * size.height)
        }
        return nil
    }

    /// Whether OCR reads `sentence` in `view`, compared without case and spaces.
    static func reads(_ sentence: String, in view: NSView) -> Bool {
        let wanted = sentence.lowercased().filter { !$0.isWhitespace }
        let text = lines(in: view).map(\.string).joined().lowercased().filter { !$0.isWhitespace }
        return text.contains(wanted)
    }

    /// A left click at `point` in window coordinates.
    static func click(_ window: NSWindow, at point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            {
                window.sendEvent(event)
            }
        }
    }

    /// The api fixture ten times over, each copy's skills and packages renamed: 140 skills, 30 update rows, 10
    /// cooldowns, 10 versions outside the range, 20 text findings and 60 doctor problems, every line wrapping.
    static func large(copies: Int = 10) -> ScopeSnapshot {
        let status = object("status.api")
        let audit = object("audit.api")
        let doctor = object("doctor.api")
        let outdated = object("outdated.api")
        func renamed(_ rows: Any?, _ keys: [String], _ copy: Int) -> [[String: Any]] {
            ((rows as? [[String: Any]]) ?? [])
                .map { row in
                    var row = row
                    for key in keys {
                        if let value = row[key] as? String { row[key] = "\(value)-\(copy)" }
                    }
                    return row
                }
        }
        func lines(_ rows: Any?, _ copy: Int) -> [String] {
            ((rows as? [String]) ?? [])
                .map { line in
                    guard let colon = line.firstIndex(of: ":") else { return line }
                    return line[..<colon] + "-\(copy)" + line[colon...]
                }
        }
        var bigStatus = status
        var bigAudit = audit
        var bigDoctor = doctor
        var bigOutdated = outdated
        let range = 1...copies
        bigStatus["entries"] = range.flatMap { renamed(status["entries"], ["skill", "package"], $0) }
        bigAudit["skills"] = range.flatMap { renamed(audit["skills"], ["skill", "package"], $0) }
        bigOutdated["packages"] = range.flatMap { renamed(outdated["packages"], ["package"], $0) }
        for key in ["problems", "warnings", "passed"] {
            bigDoctor[key] = range.flatMap { lines(doctor[key], $0) }
        }
        return ScopeSnapshot(
            status: decode(StatusDocument.self, bigStatus), audit: decode(AuditDocument.self, bigAudit),
            doctor: decode(DoctorDocument.self, bigDoctor), outdated: decode(OutdatedDocument.self, bigOutdated),
            checkedAt: Date())
    }

    static func object(_ name: String) -> [String: Any] {
        let data = Data(DesignFixtures.text(name, "json").utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T {
        DesignFixtures.decode(
            type, json: String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
        )
    }
}
