import Foundation
import Observation
import SkillcaskCore
import SkillcaskDomain

/// Runs the commands that change or check a scope: mutations through `MutationQueue` so one runs at a
/// time per scope, `doctor` without `--fix` directly. While a command runs, `current` carries its live transcript
/// and a cancel; when it ends, an `ActivityEntry` is appended (S15), `outcome` becomes the toast or the failure
/// banner (S11), and the scope's store runs its targeted refresh.
///
/// Wired here: `sync` (`install`), `check` (`doctor`), `repair` (`doctor --fix`), `restoreFromLock`
/// (`install --frozen`). Add, update, remove and adopt run from their sheets through `SheetRun`, which calls
/// `run(_:title:outcome:in:from:)` with `.sheet`: the same bookkeeping applies, but the progress and a failure stay
/// in the sheet (S11) instead of the list header and banner. Add Skill stays open after an add, so its runs set no
/// toast; the sheet leaves one through `announce(_:emphasis:id:)` when it closes (`AddSkillVisit`).
@MainActor @Observable public final class ActionRunner {
    /// Where a run was started, which decides where its progress and failure show (S11): the list header and the
    /// banner for the toolbar, menus and Overview; inside the sheet for a sheet's run.
    public enum Origin: Hashable, Sendable {
        case window
        case sheet
    }

    /// How a run ended, for the one that started it (`SheetRun`).
    public enum RunEnd: Hashable, Sendable {
        case succeeded
        /// The failure as the banner would word it, `Cancelled.` included.
        case failed(UserMessage)
    }

    /// A command in flight: what the list header and the Activity drawer show.
    public struct RunningAction: Identifiable {
        public let id: UUID
        /// "Syncing…", from `ActionCopy`.
        public let title: String
        public let scope: Scope
        /// `skillcask install`, for the Activity drawer.
        public let command: String
        public let startedAt: Date
        /// `.sheet`: the list header leaves the progress to the sheet.
        public let origin: Origin
        public fileprivate(set) var lines: [OutputLine] = []
        /// Lines dropped from the front of `lines` to keep a long run within `ActivityEntry.transcriptLimit`.
        public fileprivate(set) var omittedLines = 0
        fileprivate let task: Task<RunEnd, Never>?

        /// Terminates the child (SIGTERM, then SIGKILL after the grace period); the outcome reads `Cancelled.`
        public func cancel() {
            task?.cancel()
        }
    }

    /// What the window shows when a run ends: the toast at the bottom of the list column, or the banner at its top.
    public enum Outcome: Identifiable, Hashable, Sendable {
        case toast(ToastMessage)
        case banner(UserMessage, id: UUID)

        public var id: UUID {
            switch self {
            case .toast(let message): message.id
            case .banner(_, let id): id
            }
        }
    }

    private let queue: MutationQueue

    // MARK: - State

    public private(set) var current: RunningAction?
    /// This session's finished runs, newest first, at most `ActivityEntry.limit` (S15). Nothing is written to disk.
    public private(set) var activity: [ActivityEntry] = []
    /// Every run recorded this session, also the ones `activity` no longer keeps (the drawer's header count).
    public private(set) var sessionRunCount = 0
    /// The success toast at the bottom of the list column, bindable for `View.toast`, which clears it after 4 s.
    public var toast: ToastMessage?
    /// The failure banner at the top of the list column, if the last failed run left one.
    public private(set) var banner: UserMessage?
    /// The run `banner` reports, for its Details link.
    public private(set) var bannerID: UUID?
    /// The run whose transcript the Activity drawer should show: set by the toast's "Show details" and the banner's
    /// Details (`showDetails(of:)`). The drawer consumes it (`consumeDetailsRequest()`), which opens Activity there.
    public var detailsRequest: UUID?

    // MARK: - Activity drawer (S15)

    /// Whether the Activity drawer shows under the list. Hidden at launch; ⌥⌘L (View › Activity), the toolbar's ⋯,
    /// Settings › Advanced and the Details of a toast or banner open it, nothing else does. Session only.
    public var isActivityShown = false
    /// The run the drawer scrolls to once it is on screen, set by `consumeDetailsRequest()`; the drawer clears it.
    public private(set) var activityFocus: UUID?
    /// The rows showing their transcript: the ones the user expanded and the one Details asked for.
    public private(set) var expandedActivity: Set<UUID> = []

    /// The last run that ended in a failure banner, so Retry can run it again (never automatically).
    private struct FailedRun {
        let command: Invocation.Command
        let title: String
        let failure: String?
        /// The toast text, from the scope name and the transcript (`run`'s `report`, else its `outcome`).
        let report: @Sendable (String, [OutputLine]) -> String
        /// Whether the first run toasted; Retry ends the same way.
        let announce: Bool
        /// The toast's semibold parts.
        let emphasis: [String]
        /// The toast's tone, from the transcript (`run`'s `tone`).
        let tone: Tone?
        weak var store: ScopeStore?
        /// Set when the run ended in an integrity failure: `retry()` refuses it.
        var isIntegrity = false
    }

    @ObservationIgnored private var failedRun: FailedRun?

    public init(queue: MutationQueue) {
        self.queue = queue
    }

    /// The toast or banner of the last finished run (Running board: one toast at a time, one banner at a time).
    /// A toast replaces the banner, except an integrity banner, which stays until dismissed and can show beside the
    /// toast (Running board "Integrity failure (exit 4) and a success toast"); a banner replaces both. Reading it
    /// gives the toast when both show. Setting nil clears both.
    public var outcome: Outcome? {
        get {
            if let toast { return .toast(toast) }
            if let banner, let bannerID { return .banner(banner, id: bannerID) }
            return nil
        }
        set {
            switch newValue {
            case .toast(let message):
                toast = message
                if banner?.isIntegrity != true {
                    banner = nil
                    bannerID = nil
                }
            case .banner(let message, let id):
                banner = message
                bannerID = id
                toast = nil
            case nil:
                toast = nil
                banner = nil
                bannerID = nil
            }
        }
    }

    /// Asks the Activity drawer for run `id` (the toast's "Show details", the banner's Details).
    public func showDetails(of id: UUID) {
        detailsRequest = id
    }

    /// Opens Activity for the pending `detailsRequest` and clears it: a run of `activity` is expanded and becomes
    /// the scroll target; an id that names no run (a batch's summary toast) opens the drawer without scrolling.
    public func consumeDetailsRequest() {
        guard let id = detailsRequest else { return }
        detailsRequest = nil
        isActivityShown = true
        guard activity.contains(where: { $0.id == id }) else {
            activityFocus = nil
            return
        }
        expandedActivity.insert(id)
        activityFocus = id
    }

    /// The drawer scrolled to `activityFocus`.
    public func clearActivityFocus() {
        activityFocus = nil
    }

    /// ⌥⌘L, View › Activity, the toolbar's Show Activity, the drawer's close button.
    public func toggleActivity() {
        isActivityShown.toggle()
    }

    /// Expands or collapses the transcript of run `id`.
    public func toggleExpanded(_ id: UUID) {
        if expandedActivity.contains(id) {
            expandedActivity.remove(id)
        } else {
            expandedActivity.insert(id)
        }
    }

    /// Dismisses the banner; an integrity failure stays until this is called (Running board).
    public func dismissBanner() {
        banner = nil
        bannerID = nil
    }

    /// Re-runs the last action that failed (same command, title and outcome, in the same scope) and clears its
    /// banner. Only the user's Retry calls it: nothing is retried automatically, and the banner offers Retry for
    /// network failures alone (`FailureBanner.showsRetry`). An integrity failure is never re-run, even if
    /// something calls this anyway: the failed run stays recorded but marked, and the call returns nil. It also
    /// returns nil when nothing has failed since the last success, when the scope's store is gone, or while another
    /// run is in flight; otherwise it returns the new run's task.
    @discardableResult public func retry() -> Task<Void, Never>? {
        guard let failedRun, !failedRun.isIntegrity, let store = failedRun.store, current == nil else { return nil }
        outcome = nil
        return Task {
            await run(
                failedRun.command, title: failedRun.title, failure: failedRun.failure, outcome: { _ in "" },
                report: failedRun.report, emphasis: failedRun.emphasis, tone: failedRun.tone, in: store,
                announce: failedRun.announce)
        }
    }

    /// Previews: shows `title` as a run in flight in `scope`, with no child process behind it.
    func preloadRunning(
        title: String, in scope: Scope, from origin: Origin = .window, startedAt: Date = Date(),
        lines: [OutputLine] = [], command: String = ""
    ) {
        current = RunningAction(
            id: UUID(), title: title, scope: scope, command: command, startedAt: startedAt, origin: origin,
            lines: lines, task: nil)
    }

    /// Previews: this session's finished runs, newest first, with `expanded` showing their transcripts.
    func preloadActivity(_ entries: [ActivityEntry], expanded: Set<UUID> = [], shown: Bool = true) {
        activity = Array(entries.prefix(ActivityEntry.limit))
        sessionRunCount = entries.count
        expandedActivity = expanded
        isActivityShown = shown
    }

    // MARK: - Derived

    /// Whether any run is in flight. One run at a time in the whole app (`run` refuses a second while `current` is
    /// set), so every scope's toolbar, menu and Overview actions that start a run or open a mutating sheet (Add
    /// Skill… included, through `ToolbarRules.canAddSkill`) are disabled while it is true.
    public var isRunning: Bool {
        current != nil
    }

    // MARK: - Actions

    /// The three runs the toolbar, the Overview and the Scope menu start.
    public enum Action: Hashable, Sendable {
        case sync
        case check
        case repair
        /// Set Up = `init`: creates skills.toml and links the agents found (Overview-States "Folder without
        /// skills.toml").
        case setUp
        /// Reinstall from lock = `install --frozen` (Security tab): re-places every locked skill whose folder does
        /// not match skills.lock and never rewrites the lock (`src/commands.rs` `install`, `materialize`).
        case restoreFromLock
    }

    /// Starts `action` from a button: the runner owns the task, the view calls one line.
    public func start(_ action: Action, in store: ScopeStore) {
        Task {
            switch action {
            case .sync: await sync(in: store)
            case .check: await check(in: store)
            case .repair: await repair(in: store)
            case .setUp: await setUp(in: store)
            case .restoreFromLock: await restoreFromLock(in: store)
            }
        }
    }

    /// Sync = plain `install`. Where skills.toml and skills.lock agree it installs what the lock pins
    /// (at most `fill_new_keys` adds keys an old lock lacks, never another version): "Syncing with skills.lock…",
    /// and the toast counts the CLI's `installed <skill> (<package> <version>)` lines (`src/commands.rs`
    /// `materialize`): "Synced api · 1 skill installed" (Flow-F5). Where a row needs sync (skills.toml and the lock
    /// disagree, `syncResolves`), the same `install` resolves skills.toml and rewrites the lock first
    /// (`src/commands.rs` `install`: `settle_deps`, `settle_and_save`), so the title and toast say that instead.
    /// Not `install --frozen` for the agreeing case: on a snapshot older than a skills.toml edit it would fail
    /// where Sync used to work.
    public func sync(in store: ScopeStore) async {
        let resolves = Self.syncResolves(store.snapshot)
        await run(
            .install(frozen: false), title: resolves ? ActionCopy.resolving : ActionCopy.syncing,
            failure: ActionCopy.couldNotSync, outcome: ActionCopy.synced,
            report: { scope, transcript in
                let installed = MutationReport(verbLines: Self.stdout(of: transcript)).installed.count
                return resolves
                    ? ActionCopy.resolved(scope, installed: installed) : ActionCopy.synced(scope, installed: installed)
            },
            in: store)
    }

    /// A row's skills.toml entry and skills.lock disagree (`Health.needsSync`: drift, not in the lock, not in the
    /// manifest), so `install` resolves and writes the lock before it installs.
    public nonisolated static func syncResolves(_ snapshot: ScopeSnapshot?) -> Bool {
        (snapshot?.entries ?? []).contains { if case .needsSync = $0.health { true } else { false } }
    }

    /// A finished run's stdout as lines, uncapped: from the result's bytes, else (a client that only streamed) the
    /// streamed stdout lines.
    nonisolated static func stdoutLines(of run: RunResult, streamed: [OutputLine]) -> [OutputLine] {
        guard !run.stdout.isEmpty else {
            return streamed.filter { if case .stdout = $0 { true } else { false } }
        }
        return run.stdoutText.split(separator: "\n", omittingEmptySubsequences: false).map { .stdout(String($0)) }
    }

    /// A finished run's whole output for its toast: stdout as `stdoutLines(of:streamed:)`, then stderr from the
    /// result (else the streamed stderr lines). Uncapped, unlike the live transcript, so a long run's toast still
    /// counts every line; the order between the two streams is not kept (the reports read one kind each).
    nonisolated static func outputLines(of run: RunResult, streamed: [OutputLine]) -> [OutputLine] {
        let stderr: [OutputLine] =
            run.stderr.isEmpty
            ? streamed.filter { if case .stderr = $0 { true } else { false } }
            : run.stderr.split(separator: "\n").map { .stderr(String($0)) }
        return stdoutLines(of: run, streamed: streamed) + stderr
    }

    /// The stdout lines of a transcript, joined, for `MutationReport(verbLines:)`.
    nonisolated static func stdout(of transcript: [OutputLine]) -> String {
        transcript.compactMap { line -> String? in
            if case .stdout(let text) = line { text } else { nil }
        }
        .joined(separator: "\n")
    }

    /// Check = `doctor` without `--fix`: reports, changes nothing.
    public func check(in store: ScopeStore) async {
        await run(
            .doctor(fix: false), title: ActionCopy.checking, failure: ActionCopy.couldNotCheck,
            outcome: ActionCopy.checked,
            in: store)
    }

    /// Repair = `doctor --fix --json`: links, the git index and the gitignore block; downloads nothing. With
    /// problems left the CLI prints `ok: false` and exits 1 (`src/commands.rs` `doctor`): the toast says how many
    /// it fixed and how many are left, in the warning tone.
    public func repair(in store: ScopeStore) async {
        await run(
            .doctor(fix: true), title: ActionCopy.repairing, failure: ActionCopy.couldNotRepair,
            outcome: ActionCopy.repaired,
            report: { scope, transcript in
                guard let document = Self.doctorDocument(in: transcript), !document.ok else {
                    return ActionCopy.repaired(scope)
                }
                return ActionCopy.repaired(scope, fixed: document.fixed.count, left: document.problems.count)
            },
            tone: { transcript in Self.doctorDocument(in: transcript)?.ok == false ? .warning : .success },
            in: store)
    }

    /// The `doctor --json` document on a transcript's stdout (one line, `print_json`).
    nonisolated static func doctorDocument(in transcript: [OutputLine]) -> DoctorDocument? {
        try? JSONDecoder().decode(DoctorDocument.self, from: Data(stdout(of: transcript).utf8))
    }

    /// Set Up = `init`: writes skills.toml in the scope's folder; downloads nothing.
    public func setUp(in store: ScopeStore) async {
        await run(
            .initialize, title: ActionCopy.settingUp, failure: ActionCopy.couldNotSetUp, outcome: ActionCopy.setUp,
            in: store)
    }

    /// Reinstall from lock = `install --frozen`: puts back the locked files of every skill whose folder differs
    /// from skills.lock or is missing; fails, changing nothing, when the lock is out of date with skills.toml.
    public func restoreFromLock(in store: ScopeStore) async {
        await run(
            .install(frozen: true), title: ActionCopy.restoring, failure: ActionCopy.couldNotRestore,
            outcome: ActionCopy.restored,
            in: store)
    }

    /// Runs `command` in `store`'s scope with a live transcript, records it, shows its outcome and asks the store
    /// for its targeted refresh. One run at a time in the whole app: a second call while `current` is set does
    /// nothing and returns nil, because the toolbar is disabled meanwhile. Success is a toast unless `announce` is
    /// false (a batch item: the batch shows one summary through `announce(_:)`; an add of the Add Skill sheet: the
    /// sheet stays open and toasts when it closes); a failure is the banner for
    /// `.window` and only the returned `.failed` for `.sheet`, which shows it in place. A sheet's run never touches
    /// the window's banner or its Retry. Cancelling the calling task cancels the run. `failure` is the failure's
    /// title as Copy words it ("Couldn’t sync."); nil falls back to `OutcomeCopy.couldNot(title)` (that reads
    /// "Couldn’t Syncing…." for a progressive title, so every caller should pass one).
    ///
    /// The returned value arrives after the scope's refresh. `onEnd` gets the same end, and the run's id (its
    /// `ActivityEntry`), as soon as the run is recorded and its toast set, before that refresh: a sheet that closes
    /// on success closes there, so the toast shows while the list header carries the refresh (S11). Not called for a
    /// refused run.
    /// `emphasis` are the toast's semibold parts (the skill names). `onStdout` gets the stdout of a run that
    /// exited 0, whole, from the run's result (the live transcript keeps only its last
    /// `ActivityEntry.transcriptLimit` lines), just before `onEnd`.
    @discardableResult public func run(
        _ command: Invocation.Command, title: String, failure: String? = nil,
        outcome outcomeText: @escaping @Sendable (String) -> String,
        report: (@Sendable (_ scope: String, _ transcript: [OutputLine]) -> String)? = nil, emphasis: [String] = [],
        tone: Tone? = nil,
        in store: ScopeStore,
        from origin: Origin = .window,
        announce: Bool = true, onEnd: (@MainActor @Sendable (RunEnd, UUID) -> Void)? = nil,
        onStdout: (@MainActor @Sendable (_ stdout: [OutputLine]) -> Void)? = nil
    ) async -> RunEnd? {
        guard current == nil else { return nil }
        let failureTitle = failure ?? OutcomeCopy.couldNot(title)
        let report: @Sendable (String, [OutputLine]) -> String = report ?? { scope, _ in outcomeText(scope) }
        if origin == .window {
            failedRun = FailedRun(
                command: command, title: title, failure: failure, report: report, announce: announce,
                emphasis: emphasis, tone: tone, store: store)
        }
        let invocation: Invocation
        do {
            invocation = try Invocation(command, in: store.scope, capabilities: store.capabilities)
        } catch {
            let id = UUID()
            let end = finish(
                id: id, title: title, failure: failureTitle, command: ActionCopy.unbuilt, startedAt: Date(),
                duration: .zero, status: nil, error: error, transcript: [], outcomeText: report, origin: origin,
                announce: announce, store: store,
                record: .init(isMutation: false, expectsDocument: false, emphasis: emphasis, tone: tone))
            onEnd?(end, id)
            return end
        }
        let id = UUID()
        let startedAt = Date()
        let client = store.client
        let queue = queue
        // The lines reach the transcript in the order the client delivered them, through one stream drained by one
        // loop on the main actor; the run completes only after the loop has appended the last one.
        let (lineStream, lineSink) = AsyncStream<OutputLine>.makeStream()
        let delivery = Task { [weak self] in
            for await line in lineStream {
                self?.append(line, to: id)
            }
        }
        let task = Task { [weak self] () -> RunEnd in
            let onLine: @Sendable (OutputLine) -> Void = { line in lineSink.yield(line) }
            let result: Result<RunResult, CLIError>
            do {
                if invocation.isMutation {
                    result = .success(
                        try await queue.enqueue(in: invocation.scope) {
                            try await client.run(invocation, onLine: onLine)
                        })
                } else {
                    result = .success(try await client.run(invocation, onLine: onLine))
                }
            } catch let error as CLIError {
                result = .failure(error)
            } catch is CancellationError {
                result = .failure(.cancelled)
            } catch {
                result = .failure(.launchFailed(String(describing: error)))
            }
            lineSink.finish()
            await delivery.value
            guard let self else {
                return .failed(ErrorCopy.message(for: .cancelled, title: failureTitle))
            }
            return await complete(
                id: id, title: title, failure: failureTitle, invocation: invocation, result: result,
                outcomeText: report, emphasis: emphasis, tone: tone, origin: origin,
                announce: announce, store: store, onEnd: onEnd, onStdout: onStdout)
        }
        current = RunningAction(
            id: id, title: title, scope: store.scope, command: invocation.displayCommand, startedAt: startedAt,
            origin: origin, task: task)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// The one toast of runs that ended with `announce: false`: a batch (Adopt All: "Adopted 9 skills"), or the adds
    /// of an Add Skill sheet once it closes. `id` names the run "Show details" opens (the one add of a sheet); a
    /// summary names none.
    public func announce(_ text: String, emphasis: [String] = [], id: UUID = UUID()) {
        outcome = .toast(ToastMessage(id: id, text: text, emphasizing: emphasis))
    }

    /// Cancels the running command, if any.
    public func cancel() {
        current?.cancel()
    }

    // MARK: - Bookkeeping

    private func append(_ line: OutputLine, to id: UUID) {
        guard current?.id == id else { return }
        current?.lines.append(line)
        // Drop in chunks, so a chatty run does not shift the whole array on every line past the limit.
        let excess = (current?.lines.count ?? 0) - ActivityEntry.transcriptLimit
        if excess >= Self.trimChunk {
            current?.lines.removeFirst(excess)
            current?.omittedLines += excess
        }
    }

    /// How far past `ActivityEntry.transcriptLimit` a live transcript grows before its oldest lines are dropped.
    private static let trimChunk = 256

    /// What `finish` records besides the run's outcome.
    private struct Record {
        let isMutation: Bool
        let expectsDocument: Bool
        var environmentOverrides: [String] = []
        var omittedLines = 0
        /// The toast's semibold parts.
        var emphasis: [String] = []
        /// The toast's tone from the transcript; nil is `.success`.
        var tone: Tone?
        /// What the toast and its tone read, when it differs from the recorded transcript: the run's whole output
        /// (`outputLines(of:streamed:)`); nil reads the transcript.
        var output: [OutputLine]?
    }

    /// The tone of a run's toast, read from its transcript.
    public typealias Tone = @Sendable (_ transcript: [OutputLine]) -> ToastMessage.Tone

    private func complete(
        id: UUID, title: String, failure: String, invocation: Invocation, result: Result<RunResult, CLIError>,
        outcomeText: @escaping @Sendable (String, [OutputLine]) -> String, emphasis: [String], tone: Tone?,
        origin: Origin, announce: Bool, store: ScopeStore, onEnd: (@MainActor @Sendable (RunEnd, UUID) -> Void)?,
        onStdout: (@MainActor @Sendable ([OutputLine]) -> Void)? = nil
    ) async -> RunEnd {
        guard let running = current, running.id == id else {
            return .failed(ErrorCopy.message(for: .cancelled, title: failure))
        }
        let duration = Duration.seconds(Date().timeIntervalSince(running.startedAt))
        let verdict: CLIError?
        let status: ExitStatus?
        var repair: DoctorDocument?
        var record = Record(
            isMutation: invocation.isMutation, expectsDocument: invocation.expectsDocument,
            omittedLines: running.omittedLines, emphasis: emphasis, tone: tone)
        switch result {
        case .success(let run):
            status = run.status
            record.environmentOverrides = run.environmentOverrides
            record.output = Self.outputLines(of: run, streamed: running.lines)
            verdict = Self.verdict(of: run)
            // Repair's document is the only record of what it fixed: the follow-up refresh shows it (S12).
            if verdict == nil, run.invocation.command == .doctor(fix: true) {
                repair = try? run.document(DoctorDocument.self)
            }
        case .failure(let error):
            status = nil
            verdict = error
        }
        let end = finish(
            id: id, title: title, failure: failure, command: running.command, startedAt: running.startedAt,
            duration: duration,
            status: status, error: verdict, transcript: running.lines, outcomeText: outcomeText, origin: origin,
            announce: announce, store: store, record: record)
        if case .succeeded = end, case .success(let run) = result, let onStdout {
            onStdout(Self.stdoutLines(of: run, streamed: running.lines))
        }
        onEnd?(end, id)
        // Always refresh afterwards: a cancelled or failed run may have changed files. In a task of its
        // own, which does not inherit this one's cancellation: after Cancel the reads must still run.
        let kept = repair
        await Task { await store.refreshAfterMutation(repair: kept) }.value
        return end
    }

    private func finish(
        id: UUID, title: String, failure: String, command: String, startedAt: Date, duration: Duration,
        status: ExitStatus?,
        error: CLIError?, transcript: [OutputLine], outcomeText: (String, [OutputLine]) -> String, origin: Origin,
        announce: Bool,
        store: ScopeStore, record: Record
    ) -> RunEnd {
        current = nil
        let output = record.output ?? transcript
        let said = error == nil ? outcomeText(ShellCopy.name(of: store.scope), output) : failure
        insert(
            ActivityEntry(
                id: id, title: title, headline: said, command: command, scope: store.scope, startedAt: startedAt,
                duration: duration, status: status, error: error, transcript: transcript,
                omittedLines: record.omittedLines, isMutation: record.isMutation,
                expectsDocument: record.expectsDocument, environmentOverrides: record.environmentOverrides))
        if let error {
            let message = ErrorCopy.message(for: error, title: failure)
            switch origin {
            case .window:
                failedRun?.isIntegrity = message.isIntegrity
                outcome = .banner(message, id: id)
            case .sheet:
                // The sheet shows the message and offers its own retry; the window's banner and Retry stay as they were.
                break
            }
            return .failed(message)
        }
        if origin == .window {
            failedRun = nil
        }
        if announce {
            outcome = .toast(
                ToastMessage(
                    id: id, text: said, emphasizing: record.emphasis, tone: record.tone?(output) ?? .success))
        }
        return .succeeded
    }

    /// Records a read the user started (`ScopeStore`, `ReviewStore` through their `ActivitySink`).
    public func record(_ entry: ActivityEntry) {
        insert(entry)
    }

    /// Adds `entry` as the newest run, dropping the oldest past `ActivityEntry.limit` (and their expansion).
    private func insert(_ entry: ActivityEntry) {
        sessionRunCount += 1
        activity.insert(entry, at: 0)
        guard activity.count > ActivityEntry.limit else { return }
        let dropped = activity[ActivityEntry.limit...].map(\.id)
        activity.removeLast(activity.count - ActivityEntry.limit)
        expandedActivity.subtract(dropped)
    }

    /// The one decoding rule: a command that prints a document succeeded when it exited 0 or 1 (D32:
    /// `doctor` exits 1 with problems) and stdout is a JSON document; a signal, any other exit, or stdout that
    /// is not JSON is a failure. A command without `--json` is judged by its exit.
    static func verdict(of run: RunResult) -> CLIError? {
        guard run.invocation.expectsDocument else { return run.failure() }
        switch run.status {
        case .exited(0), .exited(1):
            if run.stdout.isEmpty {
                return run.failure() ?? .noDocument
            }
            // Repair's document is its only record of what it fixed: one that does not decode is no success.
            if run.invocation.command == .doctor(fix: true),
                (try? JSONDecoder().decode(DoctorDocument.self, from: run.stdout)) == nil
            {
                return .decode("stdout is not a doctor document", raw: run.stdout)
            }
            if (try? JSONDecoder().decode(JSONValue.self, from: run.stdout)) != nil {
                return nil
            }
            return .decode("stdout is not a JSON document", raw: run.stdout)
        default:
            return run.failure()
        }
    }
}
