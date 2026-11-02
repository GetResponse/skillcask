import CoreServices
import Foundation
import os

/// Says on the main actor that something relevant changed under a set of directories. `start` replaces whatever
/// was watched before with a stream from now on: `excluding` (at most eight, `WatchPlan.heavyDirectories`) are left
/// out of it, and only an event `accepts` (a path, and whether it is a rescan: events coalesced or dropped) is
/// delivered; `accepts` runs off the main actor. `retarget` swaps `accepts` of the running stream, from its next
/// delivery on, for a plan whose roots and exclusions did not change, so no change is lost to a restart. `stop` ends
/// delivery, and no callback arrives after it.
@MainActor public protocol FileWatching: AnyObject {
    func start(
        roots: [String], excluding: [String], accepts: @escaping WatchFilter, onChange: @escaping @MainActor () -> Void)
    func retarget(_ accepts: @escaping WatchFilter)
    func stop()
}

/// Whether a reported path, rescan or not, is delivered (`WatchPlan.accepts`).
public typealias WatchFilter = @Sendable (_ path: String, _ rescan: Bool) -> Bool

/// Watches nothing: the fixture boot, previews and tests that drive no disk.
@MainActor public final class NoFileWatcher: FileWatching {
    public init() {}
    public func start(
        roots: [String], excluding: [String], accepts: @escaping WatchFilter,
        onChange: @escaping @MainActor () -> Void
    ) {}
    public func retarget(_ accepts: @escaping WatchFilter) {}
    public func stop() {}
}

/// An FSEvents stream over `roots` (file-level events, the roots themselves watched for rename or removal),
/// delivered after `latency` on a private serial queue, where the paths are bridged and filtered; only a delivery
/// the filter accepts hops to the main actor, so churn elsewhere in a project costs the window nothing. The filter
/// sits behind a lock, so `retarget` swaps it from the main actor while the queue reads it. The stream always starts
/// from now, so it never replays history (no `HistoryDone` sentinel; one would be skipped anyway). The stream
/// retains its handler through the context; `stop()` tears the stream down on its queue (no callback runs meanwhile)
/// and disarms the main-actor side, so a hop already queued delivers nothing. `deinit` stops a stream the owner
/// forgot.
@MainActor public final class FSEventsWatcher: FileWatching {
    /// Seconds FSEvents gathers events before one delivery.
    public let latency: TimeInterval
    /// `nonisolated(unsafe)` only so `deinit` can tear it down; every other access is on the main actor.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var handler: Handler?
    private let queue = DispatchQueue(label: "skillcask.live-refresh.fsevents")

    /// The main-actor end of one stream; disarmed by `stop()`.
    @MainActor private final class Delivery {
        var isArmed = true
        let onChange: @MainActor () -> Void
        init(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    }

    /// What the stream's context holds; retained and released by the stream.
    private final class Handler: Sendable {
        let accepts: OSAllocatedUnfairLock<WatchFilter>
        let delivery: Delivery
        init(accepts: @escaping WatchFilter, delivery: Delivery) {
            self.accepts = OSAllocatedUnfairLock(initialState: accepts)
            self.delivery = delivery
        }
    }

    public init(latency: TimeInterval = 0.5) {
        self.latency = latency
    }

    deinit {
        if let stream {
            Self.tearDown(stream, on: queue)
        }
    }

    public func start(
        roots: [String], excluding: [String], accepts: @escaping WatchFilter,
        onChange: @escaping @MainActor () -> Void
    ) {
        stop()
        guard !roots.isEmpty else { return }
        let handler = Handler(accepts: accepts, delivery: Delivery(onChange))
        let retained = Unmanaged.passRetained(handler)
        defer { retained.release() }
        var context = FSEventStreamContext(
            version: 0, info: retained.toOpaque(),
            retain: Self.retainHandler, release: Self.releaseHandler,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, Self.callback, &context, roots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        if !excluding.isEmpty {
            _ = FSEventStreamSetExclusionPaths(stream, excluding as CFArray)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            Self.tearDown(stream, on: queue)
            return
        }
        self.stream = stream
        self.handler = handler
    }

    public func retarget(_ accepts: @escaping WatchFilter) {
        handler?.accepts.withLock { $0 = accepts }
    }

    public func stop() {
        handler?.delivery.isArmed = false
        handler = nil
        if let stream {
            Self.tearDown(stream, on: queue)
            self.stream = nil
        }
    }

    /// Stops and invalidates on the stream's own queue, so no callback is running when it returns.
    private nonisolated static func tearDown(_ stream: FSEventStreamRef, on queue: DispatchQueue) {
        nonisolated(unsafe) let stream = stream
        queue.sync {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
        }
        FSEventStreamRelease(stream)
    }

    // The stream's callbacks run on its queue, or wherever it is deallocated: `nonisolated` statics, never closures
    // written inside a main-actor method, which Swift 6 would check for the main actor at run time.
    private nonisolated static let retainHandler: CFAllocatorRetainCallBack = { info in
        info.map { UnsafeRawPointer(Unmanaged<Handler>.fromOpaque($0).retain().toOpaque()) }
    }
    private nonisolated static let releaseHandler: CFAllocatorReleaseCallBack = { info in
        if let info { Unmanaged<Handler>.fromOpaque(info).release() }
    }

    /// The flags after which the reported paths do not cover what changed.
    nonisolated static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    /// Whether one delivery reaches the main actor: an event `accepts` takes, its path paired with its flags. A
    /// `HistoryDone` sentinel is no change and is skipped.
    nonisolated static func delivers(
        paths: [String], flags: [FSEventStreamEventFlags], accepts: (String, Bool) -> Bool
    ) -> Bool {
        zip(paths, flags)
            .contains { path, flag in
                flag & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) == 0
                    && accepts(path, flag & rescanFlags != 0)
            }
    }

    /// Runs on the stream's private queue; hops to the main actor only with something to deliver.
    private nonisolated static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
        let reported = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: flags, count: count))
        let accepts = handler.accepts.withLock { $0 }
        guard delivers(paths: reported, flags: flags, accepts: accepts) else { return }
        let delivery = handler.delivery
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if delivery.isArmed {
                    delivery.onChange()
                }
            }
        }
    }
}
