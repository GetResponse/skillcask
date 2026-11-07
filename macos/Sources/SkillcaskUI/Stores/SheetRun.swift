import Foundation
import Observation
import SkillcaskCore

/// The mutation of one sheet (S7 Update, S8 Add, S9 Adopt): S11 keeps a sheet's progress inside the sheet, Cancel
/// stops the run while it is in flight, success closes the sheet with the runner's toast, and a failure leaves the
/// sheet open with its message. One per sheet presentation, held by the sheet as `@State`.
///
/// Every command goes through `ActionRunner.run(_:title:outcome:in:from:announce:)` with `.sheet`, so the
/// one-run-at-a-time rule, `MutationQueue`, the Activity entries and the scope's refresh stay the runner's; this
/// only tracks what the sheet draws. A sheet's run never touches the window's banner or its Retry.
///
/// Two shapes:
/// - `start`: one command (Update, Add, Adopt one skill). Cancel terminates it. The phase ends as soon as the run is
///   recorded (`ActionRunner.run`'s `onEnd`), before the scope's refresh: at exit 0 the sheet closes at once, so the
///   toast shows while the list header carries the refresh (S11), and the progress never outlives the runner's
///   `current` (no frame shows the progress block without its transcript).
/// - `startBatch`: one command per item, in order (Adopt-States "Adopting 9 skills · 4 of 9"): each item gets its
///   own result and duration, a failure stops the rest, Cancel stops after the current item (finished items stay),
///   one summary toast at the end instead of one per item, and the sheet can close only once the batch ended.
@MainActor @Observable public final class SheetRun {
    public enum Phase: Hashable, Sendable {
        /// Nothing started yet.
        case idle
        /// In flight; `title` is the runner's ("Updating pdf…") or the batch's ("Adopting 9 skills…").
        case running(title: String)
        /// Ended in a failure or a cancel (then the message's `reason` is `Cancelled.`), or never started because
        /// another command was running (`refusal`); the sheet shows the message and stays open. A batch that
        /// failed has run the items before the failing one.
        case failed(UserMessage)
        /// A batch stopped by Cancel after its current item; the finished items stay done.
        case stopped
        /// Ended with every command at exit 0; `onSuccess` has run.
        case succeeded
    }

    /// One row of a batch (Adopt-States "Batch progress — per-item result").
    public struct Item: Identifiable, Hashable, Sendable {
        public enum State: Hashable, Sendable {
            case waiting
            case running
            case done(Duration)
            case failed(UserMessage, Duration)
            /// Not run: an earlier item failed or Cancel stopped the batch.
            case skipped
        }

        /// The skill (or package) the item acts on.
        public let id: String
        public internal(set) var state: State = .waiting
        /// What the CLI's lines said about a finished item (Adopt-States "Adopted 4.0.1 · copy kept"); nil when the
        /// batch has no `itemNote` or the item did not succeed.
        public internal(set) var note: String?
    }

    public private(set) var phase: Phase = .idle
    /// The batch's rows in run order; empty for a single command.
    public private(set) var items: [Item] = []
    /// The last single command's run (its `ActivityEntry` id), set when it ends: the failure's Details show its
    /// transcript in place, since Activity cannot open over a sheet.
    public private(set) var runID: UUID?
    @ObservationIgnored private weak var runner: ActionRunner?
    /// Bumped by every `start`/`startBatch`; a single start ends only while it is still the newest.
    @ObservationIgnored private var startToken = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Cancel during a batch: let the current item finish, run no more.
    @ObservationIgnored private var stopAfterCurrent = false
    /// The stdout of the batch item that just exited 0, whole (`ActionRunner.run`'s `onStdout`), for `itemNote`.
    @ObservationIgnored private var itemStdout: [OutputLine]?

    public init() {}

    // MARK: - Derived

    public var isRunning: Bool {
        if case .running = phase { true } else { false }
    }

    /// Cancel stops the run while it is in flight (S7: until the CLI reports done); otherwise it closes the sheet.
    public var canCancel: Bool {
        isRunning
    }

    /// The sheet may close (Cancel, Esc, `interactiveDismissDisabled`): never while its run or batch is in flight.
    public var canClose: Bool {
        !isRunning
    }

    /// The runner's live action while this sheet's command is in flight, for the progress block: its title,
    /// command, start time and transcript lines.
    public var action: ActionRunner.RunningAction? {
        guard isRunning, let current = runner?.current, current.origin == .sheet else { return nil }
        return current
    }

    /// The failure the sheet shows; nil otherwise.
    public var failure: UserMessage? {
        if case .failed(let message) = phase { message } else { nil }
    }

    /// The recorded run behind `failure`, for the in-sheet Details: nil without a failure, for a refusal (nothing
    /// ran), or once Activity no longer keeps it.
    public var failedEntry: ActionRunner.ActivityEntry? {
        guard failure != nil, let runID else { return nil }
        return runner?.activity.first { $0.id == runID }
    }

    /// Batch items that ended at exit 0, for "4 of 9" and the summary.
    public var doneCount: Int {
        items.filter { if case .done = $0.state { true } else { false } }.count
    }

    // MARK: - One command

    /// Runs `command` in `store`'s scope through `runner`, from the sheet. On exit 0 `onSuccess` runs (the sheet
    /// closes itself there; the runner has set the toast); on a failure the phase holds the message. Returns the
    /// task, or nil when this sheet or the app already runs something (for the app, the phase holds `refusal`).
    /// `failure` is the failure's title from Copy ("Couldn’t adopt caveman."); nil falls back to
    /// `OutcomeCopy.couldNot(title)`. `report` builds the toast from the transcript
    /// instead of `outcome` (Adopt: "Adopted caveman (4.0.1)" from the CLI's `added` line); `emphasis` are its
    /// semibold parts; `tone` the toast's tone from the transcript.
    @discardableResult public func start(
        _ command: Invocation.Command, title: String, failure: String? = nil,
        outcome: @escaping @Sendable (String) -> String,
        report: (@Sendable (_ scope: String, _ transcript: [OutputLine]) -> String)? = nil, emphasis: [String] = [],
        tone: ActionRunner.Tone? = nil, in store: ScopeStore, runner: ActionRunner,
        onSuccess: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        let failureTitle = failure ?? OutcomeCopy.couldNot(title)
        guard begin(title: title, failure: failureTitle, runner: runner) else { return nil }
        items = []
        runID = nil
        // Each start has its own token: a retry may start while the previous run's refresh still runs, and that
        // older task's fallback (or a late `onEnd`) must never end the newer run.
        let token = startToken
        let task = Task {
            let end = await runner.run(
                command, title: title, failure: failureTitle, outcome: outcome, report: report, emphasis: emphasis,
                tone: tone, in: store, from: .sheet,
                onEnd: { end, id in self.end(end, runID: id, token: token, onSuccess: onSuccess) })
            // The end normally arrived through `onEnd`, before the refresh; this covers a run that ended without it.
            if let end {
                self.end(end, runID: nil, token: token, onSuccess: onSuccess)
            } else if token == startToken, isRunning {
                phase = .failed(Self.refusal(failure: failureTitle))
            }
        }
        self.task = task
        return task
    }

    /// Ends a single command once, and only the start `token` names: the phase, the run's id, and `onSuccess` at
    /// exit 0.
    private func end(_ end: ActionRunner.RunEnd, runID: UUID?, token: Int, onSuccess: @MainActor () -> Void) {
        guard token == startToken, isRunning else { return }
        self.runID = runID
        switch end {
        case .succeeded:
            phase = .succeeded
            onSuccess()
        case .failed(let message):
            phase = .failed(message)
        }
    }

    // MARK: - Batch

    /// Runs `command(item)` for each of `items` in order, each titled `itemTitle(item)` in Activity, without a toast
    /// per item. A failure marks the rest skipped and ends in `.failed`; Cancel ends in `.stopped` after the current
    /// item. When at least one item succeeded, `summary(done, scope name)` is the one toast. `onSuccess` runs only
    /// when every item succeeded. Returns nil when this sheet or the app already runs something, or `items` is empty.
    /// `failure` titles the batch's refusal ("Couldn’t adopt 9 skills."); `itemFailure(item)` titles an item's failure ("Couldn’t adopt pdf."); nil falls back to
    /// `OutcomeCopy.couldNot(itemTitle(item))`. `itemReport(item, transcript)` is an item's Activity headline
    /// (nil: none); `itemNote(item, stdout)` becomes a finished item's `note`, read from the run's whole stdout.
    @discardableResult public func startBatch(
        _ items: [String], title: String, failure: String? = nil, command: @escaping (String) -> Invocation.Command,
        itemTitle: @escaping (String) -> String, itemFailure: ((String) -> String)? = nil,
        itemReport: (@Sendable (_ item: String, _ transcript: [OutputLine]) -> String)? = nil,
        itemNote: ((_ item: String, _ transcript: [OutputLine]) -> String?)? = nil,
        summary: @escaping (_ done: Int, _ scope: String) -> String, in store: ScopeStore, runner: ActionRunner,
        onSuccess: @escaping @MainActor () -> Void
    ) -> Task<Void, Never>? {
        let failureOf = { (item: String) in itemFailure?(item) ?? OutcomeCopy.couldNot(itemTitle(item)) }
        guard !items.isEmpty, begin(title: title, failure: failure ?? OutcomeCopy.couldNot(title), runner: runner)
        else {
            return nil
        }
        // A refusal mid-batch (another run slipped in) fails that item with `refusal` and skips the rest.
        self.items = items.map { Item(id: $0) }
        let task = Task {
            var end: Phase = .succeeded
            for index in self.items.indices {
                if stopAfterCurrent {
                    end = .stopped
                    break
                }
                let item = self.items[index].id
                self.items[index].state = .running
                let clock = ContinuousClock()
                let started = clock.now
                itemStdout = nil
                let result = await runner.run(
                    command(item), title: itemTitle(item), failure: failureOf(item), outcome: { _ in "" },
                    report: Self.report(itemReport, item: item), in: store, from: .sheet, announce: false,
                    onStdout: recordItemStdout)
                let duration = clock.now - started
                switch result {
                case .succeeded:
                    self.items[index].state = .done(duration)
                    if let itemNote, let stdout = itemStdout {
                        self.items[index].note = itemNote(item, stdout)
                    }
                case .failed(let message):
                    self.items[index].state = .failed(message, duration)
                    end = .failed(message)
                case nil:
                    let refusal = Self.refusal(failure: failureOf(item))
                    self.items[index].state = .failed(refusal, duration)
                    end = .failed(refusal)
                }
                if case .succeeded = end {
                    continue
                }
                break
            }
            for index in self.items.indices where self.items[index].state == .waiting {
                self.items[index].state = .skipped
            }
            if doneCount > 0 {
                runner.announce(summary(doneCount, ShellCopy.name(of: store.scope)))
            }
            phase = end
            if case .succeeded = end {
                onSuccess()
            }
        }
        self.task = task
        return task
    }

    /// `itemReport` for one item, as the runner's `report`.
    private static func report(
        _ itemReport: (@Sendable (String, [OutputLine]) -> String)?, item: String
    ) -> (@Sendable (String, [OutputLine]) -> String)? {
        guard let itemReport else { return nil }
        return { _, transcript in itemReport(item, transcript) }
    }

    /// The runner's `onStdout` for a batch item: keeps the run's whole stdout for `itemNote`.
    private var recordItemStdout: @MainActor @Sendable ([OutputLine]) -> Void {
        { [weak self] stdout in self?.itemStdout = stdout }
    }

    // MARK: - Cancel

    /// Cancel while running. One command: terminates the child, even when pressed before the runner has started
    /// it; the phase becomes `.failed` (reason `Cancelled.`). A batch: the current item finishes, the rest are
    /// skipped, the phase becomes `.stopped`.
    public func cancel() {
        guard isRunning else { return }
        if items.isEmpty {
            task?.cancel()
        } else {
            stopAfterCurrent = true
        }
    }

    /// The message of a command the runner would not start (another run is in flight), under a failure title from
    /// Copy ("Couldn’t adopt caveman.").
    static func refusal(failure: String) -> UserMessage {
        UserMessage(title: failure, reason: SheetCopy.anotherRunInFlight, severity: .neutral)
    }

    /// Starts the phase; false when this sheet already runs, or the app does (then the phase says so).
    private func begin(title: String, failure: String, runner: ActionRunner) -> Bool {
        guard !isRunning else { return false }
        guard !runner.isRunning else {
            phase = .failed(Self.refusal(failure: failure))
            return false
        }
        self.runner = runner
        startToken += 1
        stopAfterCurrent = false
        phase = .running(title: title)
        return true
    }

    // MARK: - Previews

    /// Previews: shows the sheet at `phase` with `items` (a batch midway), with no command behind it.
    func preload(phase: Phase, items: [Item] = [], runID: UUID? = nil, runner: ActionRunner? = nil) {
        self.phase = phase
        self.items = items
        self.runID = runID
        if let runner {
            self.runner = runner
        }
    }
}
