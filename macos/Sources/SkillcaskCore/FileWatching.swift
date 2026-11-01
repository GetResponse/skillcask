import CoreServices
import Foundation

/// Says on the main actor that something relevant changed under a set of directories. `start` replaces whatever
/// was watched before: `excluding` (at most eight, `WatchPlan.heavyDirectories`) are left out of the stream, and
/// only a change at a path `isRelevant` accepts, or a rescan (events coalesced or dropped), is delivered;
/// `isRelevant` may run on any thread. `resuming` picks up where the stream `stop` ended, so a change in between
/// is not lost; otherwise only changes from now on count. `stop` ends delivery, and no callback arrives after it.
@MainActor public protocol FileWatching: AnyObject {
    func start(
        roots: [String], excluding: [String], resuming: Bool, isRelevant: @escaping @Sendable (String) -> Bool,
        onChange: @escaping @MainActor () -> Void)
    func stop()
}

/// Watches nothing: the fixture boot, previews and tests that drive no disk.
@MainActor public final class NoFileWatcher: FileWatching {
    public init() {}
    public func start(
        roots: [String], excluding: [String], resuming: Bool, isRelevant: @escaping @Sendable (String) -> Bool,
        onChange: @escaping @MainActor () -> Void
    ) {}
    public func stop() {}
}

/// An FSEvents stream over `roots` (file-level events, the roots themselves watched for rename or removal),
/// delivered after `latency` on a private serial queue, where the paths are bridged and filtered; only a delivery
/// with a relevant path, or a rescan, hops to the main actor, so churn elsewhere in a project costs the window
/// nothing. Coalescing flags (`MustScanSubDirs`, dropped events, a changed root) always deliver. The stream
/// retains its handler through the context; `stop()` tears the stream down on its queue (no callback runs
/// meanwhile) and disarms the main-actor side, so a hop already queued delivers nothing. `deinit` stops a stream
/// the owner forgot.
@MainActor public final class FSEventsWatcher: FileWatching {
    /// Seconds FSEvents gathers events before one delivery.
    public let latency: TimeInterval
    /// `nonisolated(unsafe)` only so `deinit` can tear it down; every other access is on the main actor.
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var delivery: Delivery?
    /// The last event the stopped stream saw, where a resumed one starts.
    private var lastEventID: FSEventStreamEventId?
    private let queue = DispatchQueue(label: "skillcask.live-refresh.fsevents")

    /// The main-actor end of one stream; disarmed by `stop()`.
    @MainActor private final class Delivery {
        var isArmed = true
        let onChange: @MainActor () -> Void
        init(_ onChange: @escaping @MainActor () -> Void) { self.onChange = onChange }
    }

    /// What the stream's context holds; retained and released by the stream.
    private final class Handler: Sendable {
        let isRelevant: @Sendable (String) -> Bool
        let delivery: Delivery
        init(isRelevant: @escaping @Sendable (String) -> Bool, delivery: Delivery) {
            self.isRelevant = isRelevant
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
        roots: [String], excluding: [String], resuming: Bool, isRelevant: @escaping @Sendable (String) -> Bool,
        onChange: @escaping @MainActor () -> Void
    ) {
        let since = resuming ? lastEventID : nil
        stop()
        guard !roots.isEmpty else { return }
        let delivery = Delivery(onChange)
        let handler = Unmanaged.passRetained(Handler(isRelevant: isRelevant, delivery: delivery))
        defer { handler.release() }
        var context = FSEventStreamContext(
            version: 0, info: handler.toOpaque(),
            retain: Self.retainHandler, release: Self.releaseHandler,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault, Self.callback, &context, roots as CFArray,
                since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
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
        self.delivery = delivery
    }

    public func stop() {
        delivery?.isArmed = false
        delivery = nil
        if let stream {
            lastEventID = FSEventStreamGetLatestEventId(stream)
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

    /// Whether one delivery reaches the main actor: a rescan, or a relevant path.
    nonisolated static func delivers(
        paths: [String], flags: [FSEventStreamEventFlags], isRelevant: (String) -> Bool
    ) -> Bool {
        flags.contains { $0 & rescanFlags != 0 } || paths.contains(where: isRelevant)
    }

    /// Runs on the stream's private queue; hops to the main actor only with something to deliver.
    private nonisolated static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
        let reported = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        let flags = Array(UnsafeBufferPointer(start: flags, count: count))
        guard delivers(paths: reported, flags: flags, isRelevant: handler.isRelevant) else { return }
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
