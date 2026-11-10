import SkillcaskCore
import SwiftUI

/// The Add run inside the sheet (S11, AddSkill-States "Progress — live lines, Cancel"): the system spinner, the
/// run's title and the time since it started, the CLI's lines as they arrive in a mono box kept scrolled to the
/// newest, and Hide output. The sheet's footer holds Cancel. Adopt's single run draws the same block.
///
/// The box spans the block's width and has its height from the first frame, lines or not: until the CLI prints,
/// it holds one quiet placeholder line where the first line will be, so nothing moves when that arrives. It is the
/// board's 112 pt in a body as tall as the board's, and takes the extra height of a taller sheet
/// (`outputHeight(in:)`), read from the block's own size: no text is measured.
struct AddSkillProgress: View {
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

    let model: Model

    @State private var showsOutput = true

    /// The output box: `height: 112px` on the board (seven 16 pt lines).
    nonisolated static let outputHeight: CGFloat = 112
    /// The block's height in the Add Skill sheet at its board size (900×660: what the header and the footer leave).
    nonisolated static let boardHeight: CGFloat = 567

    /// The output box's height in a block `height` tall: the board's up to the board's block, then every point the
    /// block is taller, so an enlarged sheet shows more lines and keeps the board's room under the box.
    nonisolated static func outputHeight(in height: CGFloat) -> CGFloat {
        outputHeight + max(0, (height - boardHeight).rounded(.down))
    }

    var body: some View {
        GeometryReader { geometry in
            block(outputHeight: Self.outputHeight(in: geometry.size.height))
        }
    }

    private func block(outputHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            HStack(spacing: Spacing.cardGap) {
                ProgressView()
                    .controlSize(.small)
                Text(model.title)
                    .font(Font.Token.bodyEmphasis)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Spacing.s)
                TimelineView(.periodic(from: model.startedAt, by: 1)) { context in
                    Text(AddSkillCopy.elapsed(Int(context.date.timeIntervalSince(model.startedAt))))
                        .font(Font.Token.caption)
                        .foregroundStyle(Color.textSecondary)
                        .monospacedDigit()
                }
            }
            if showsOutput {
                output(height: outputHeight)
            }
            Button {
                showsOutput.toggle()
            } label: {
                Text(showsOutput ? AddSkillCopy.hideOutput : AddSkillCopy.showOutput)
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Size.cardPaddingH)
        .padding(.horizontal, Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.title)
    }

    private func output(height: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.lines.isEmpty {
                    Text(AddSkillCopy.waitingForOutput)
                        .font(Font.Token.monoSmall)
                        .foregroundStyle(Color.textTertiary)
                }
                ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                    Text(Self.text(of: line))
                        .font(Font.Token.monoSmall)
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, Spacing.s)
            .padding(.horizontal, Spacing.cardGap)
            // An empty box has no line to stretch it: without this it is as narrow as its padding.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.surfaceGrouped, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }

    static func text(of line: OutputLine) -> String {
        switch line {
        case .stdout(let text), .stderr(let text): text
        }
    }
}
