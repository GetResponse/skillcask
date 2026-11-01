import CoreServices
import Foundation
import Testing

@testable import SkillcaskCore

/// `FSEventsWatcher` against the real FSEvents service on a temporary directory: a relevant file written under a
/// root is delivered, and the relevance predicate runs off the main thread.
@Suite @MainActor struct FSEventsWatcherTests {
    /// What the predicate saw, from the stream's queue.
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        private var onMain = false

        func record(_ path: String) {
            lock.withLock {
                paths.append(path)
                onMain = onMain || Thread.isMainThread
            }
        }

        var snapshot: (paths: [String], onMain: Bool) { lock.withLock { (paths, onMain) } }
    }

    @Test(.timeLimit(.minutes(1))) func aRelevantFileIsDeliveredAndFilteredOffMain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fsevents-\(UUID().uuidString)")
        let excluded = root.appending(path: "node_modules")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonical = WatchPlan.canonical(root.path)
        let file = (canonical as NSString).appendingPathComponent("skills.lock")
        let seen = Seen()
        let watcher = FSEventsWatcher(latency: 0.1)
        let reported: Void? = await withCheckedContinuation { continuation in
            var resumed = false
            watcher.start(
                roots: [canonical], excluding: [WatchPlan.canonical(excluded.path)], resuming: false,
                isRelevant: { path in
                    seen.record(path)
                    return path == file
                }
            ) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: ())
            }
            // Written once the stream runs; written again later in case the first write raced its start.
            Task { @MainActor in
                for attempt in 0..<20 where !resumed {
                    try? Data("x".utf8).write(to: root.appending(path: "README-\(attempt).md"))
                    try? Data("x".utf8).write(to: excluded.appending(path: "dep-\(attempt).js"))
                    try? Data("v\(attempt)".utf8).write(to: URL(fileURLWithPath: file))
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if !resumed {
                    resumed = true
                    continuation.resume(returning: nil)
                }
            }
        }
        watcher.stop()
        #expect(reported != nil, "FSEvents reported no change to \(file)")
        let (paths, onMain) = seen.snapshot
        #expect(paths.contains(file) && !onMain, "the predicate runs on the stream's queue")
    }

    @Test func onlyARelevantPathOrARescanIsDelivered() {
        let relevant: (String) -> Bool = { $0.hasSuffix("skills.lock") }
        #expect(!FSEventsWatcher.delivers(paths: ["/p/a.rs", "/p/b.md"], flags: [0, 0], isRelevant: relevant))
        #expect(FSEventsWatcher.delivers(paths: ["/p/a.rs", "/p/skills.lock"], flags: [0, 0], isRelevant: relevant))
        let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        #expect(FSEventsWatcher.delivers(paths: ["/p/a.rs"], flags: [dropped], isRelevant: relevant))
    }
}
