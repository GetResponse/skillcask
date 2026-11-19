import SkillcaskCore
import SwiftUI

/// The progress of a window run in the list header (S11, Running board "Short run"). A run starts as the
/// indeterminate bar with its title (`ProgressHeader`); once it has run for `blockThreshold`, it grows into the
/// board's block on the grouped surface: the spinner, the title, the elapsed time and Cancel, the bar, the CLI's
/// newest lines in mono and Hide output. A refresh without a run (`Checking…`) stays the bar alone.
struct RunProgress: View {
    /// What the block draws: the runner's live action, or a fixed sample in previews.
    struct Model: Sendable {
        let title: String
        let startedAt: Date
        let lines: [OutputLine]

        init(title: String, startedAt: Date, lines: [OutputLine]) {
            self.title = title
            self.startedAt = startedAt
            self.lines = lines
        }

        init(_ action: ActionRunner.RunningAction) {
            self.init(title: action.title, startedAt: action.startedAt, lines: action.lines)
        }
    }

    enum Phase: Hashable {
        /// `ProgressHeader`: the bar and the title.
        case bar
        /// The board's block with elapsed time, Cancel and output.
        case block
    }

    /// How long a run shows the bar alone. The Running board draws the block at `0:03`; Check and a quick Sync end
    /// well under two seconds, so they never flash a block with a Cancel there was no time to press.
    static let blockThreshold: TimeInterval = 2
    /// The block's output keeps the newest lines: the board draws two.
    static let outputLines = 2

    let model: Model
    let onCancel: () -> Void

    @State private var showsOutput = true

    static func phase(elapsed: TimeInterval) -> Phase {
        elapsed >= blockThreshold ? .block : .bar
    }

    /// The newest `outputLines` lines, blank ones skipped.
    static func tail(_ lines: [OutputLine]) -> [String] {
        Array(lines.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(outputLines))
    }

    var body: some View {
        TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(model.startedAt)
            switch Self.phase(elapsed: elapsed) {
            case .bar:
                ProgressHeader(title: model.title)
            case .block:
                block(elapsed: elapsed)
            }
        }
    }

    // MARK: - Subviews

    /// `padding: 8px 10px; gap: 6px; border-radius: 8px; background: var(--grouped)`.
    private func block(elapsed: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            HStack(spacing: Spacing.s) {
                Spinner()
                Text(model.title)
                    .font(Font.Token.calloutSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(AdoptCopy.elapsed(elapsed))
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
                Button(RunningCopy.cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            MiniProgressBar()
            let tail = Self.tail(model.lines)
            if showsOutput, !tail.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .font(Font.Token.monoSmall)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .textSelection(.enabled)
            }
            if !tail.isEmpty {
                Button {
                    showsOutput.toggle()
                } label: {
                    Text(showsOutput ? RunningCopy.hideOutput : RunningCopy.showOutput)
                        .font(Font.Token.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.cardGap)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceGrouped, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }
}
