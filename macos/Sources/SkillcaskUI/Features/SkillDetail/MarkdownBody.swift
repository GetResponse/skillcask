import SkillcaskDomain
import SwiftUI

/// A SKILL.md body rendered read-only (Contents board `.md`): `MarkdownBlocks` gives the blocks, and each block's
/// inline Markdown goes through `MarkdownInline` into an `InlineText`, which keeps the board's 20 pt line pitch and
/// draws padded fills behind `code` and the escaped invisible characters (`‹U+202E›`, D26). Each text block selects
/// as a whole; a fenced code block is a mono `Text`.
///
/// Block spacing collapses as CSS margins do: the gap between two blocks is the larger of the first one's bottom
/// margin and the second one's top margin (`gap(after:before:)`), so a paragraph before a heading is 14 pt apart,
/// not 8 + 14.
///
/// Each block carries its index as its `.id`, so a `ScrollViewReader` can scroll to it. A flagged block (an audit
/// finding's line) is outlined as the board outlines the flagged `code` (`outline: 1px solid var(--warn);
/// outline-offset: 1px`, no fill): amber for a risky pattern, iris for an invisible character. The audit names a
/// line, not a run, so the outline goes round the block that holds the line (a board deviation). The `highlighted`
/// block (Security's "Show in file") takes the accent tint and a 2 pt accent stroke, over any flag outline.
struct MarkdownBody: View {
    let blocks: [MarkdownBlocks.Block]
    var flags: [Int: DiffFlag.Kind] = [:]
    var highlighted: Int?

    init(_ body: String) {
        blocks = MarkdownBlocks.parse(body)
    }

    init(spans: [MarkdownBlocks.Span], flags: [Int: DiffFlag.Kind] = [:], highlighted: Int? = nil) {
        blocks = spans.map(\.block)
        self.flags = flags
        self.highlighted = highlighted
    }

    // MARK: - Board values

    /// `.md { line-height: 20px }`: the pitch of every text line of the body.
    nonisolated static let lineHeight: CGFloat = 20
    /// `.md h2 { margin: 14px 0 4px }`.
    static let headingTop: CGFloat = 14
    /// `.md ol, .md ul { padding-left: 22px }`: the marker column.
    nonisolated static let listIndent: CGFloat = 22
    /// Between a list marker's end and its item's text.
    nonisolated static let markerGap: CGFloat = Spacing.inline
    /// The quote's bar; no board draws a quote, so a GitHub-like 3 pt bar.
    static let quoteBar: CGFloat = 3
    /// `outline-offset: 1px`: the flag outline stands this far off the block.
    static let flagOffset: CGFloat = Size.hairline
    /// The "Show in file" tint reaches this far past its block, so the text does not touch its stroke.
    static let highlightOutset: CGFloat = Spacing.xs

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { mark(index) }
                    .padding(.top, Self.gap(after: index > 0 ? blocks[index - 1] : nil, before: block))
                    .id(index)
            }
        }
        .foregroundStyle(Color.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - Marks

    /// How a block's mark is drawn: an optional fill and a stroke of `width`, `outset` past the block.
    struct MarkStyle: Equatable {
        let fill: Color?
        let stroke: Color
        let width: CGFloat
        let outset: CGFloat
    }

    /// The highlight while "Show in file" points at the block, whether or not it is flagged; else the flag's 1 pt
    /// outline (`statusWarningDot` for a risky pattern, `accent` for an invisible character, as `DiffLineView`) one
    /// point off the block with no fill; else nothing.
    static func markStyle(flag: DiffFlag.Kind?, highlighted: Bool) -> MarkStyle? {
        if highlighted {
            return MarkStyle(
                fill: Color.accentSoft, stroke: Color.accent, width: Size.hairline * 2, outset: highlightOutset)
        }
        let stroke: Color
        switch flag {
        case .risky: stroke = Color.statusWarningDot
        case .invisible: stroke = Color.accent
        case nil: return nil
        }
        return MarkStyle(fill: nil, stroke: stroke, width: Size.hairline, outset: flagOffset + Size.hairline)
    }

    /// The mark behind the block without moving it: `strokeBorder` keeps the stroke inside the outset rect, so a
    /// 1 pt outline at a 2 pt outset is the board's 1 px outline 1 px off.
    @ViewBuilder private func mark(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
        if let style = Self.markStyle(flag: flags[index], highlighted: highlighted == index) {
            shape
                .fill(style.fill ?? .clear)
                .overlay { shape.strokeBorder(style.stroke, lineWidth: style.width) }
                .padding(-style.outset)
        }
    }

    // MARK: - Subviews

    @ViewBuilder private func view(for block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            let style = level <= 2 ? MarkdownInline.Style.heading : MarkdownInline.Style.minorHeading
            InlineText(MarkdownInline.block(text, style: style), style: style, isHeading: true)
        case .paragraph(let text):
            InlineText(MarkdownInline.block(text, style: .body), style: .body)
        case .list(let ordered, let start, let items):
            InlineText(MarkdownInline.list(ordered: ordered, start: start, items: items, style: .body), style: .body)
        case .code(_, let text):
            Text(Self.escapesMarked(AttributedString(DiffCopy.shown(text))))
                .font(Font.Token.mono)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceGrouped, in: RoundedRectangle(cornerRadius: Radius.m))
        case .quote(let text):
            HStack(alignment: .top, spacing: Spacing.s) {
                Rectangle()
                    .fill(Color.separatorStrong)
                    .frame(width: Self.quoteBar)
                InlineText(MarkdownInline.block(text, style: .quote), style: .quote)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle()
                .fill(Color.separator)
                .frame(height: Size.hairline)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Spacing

    /// A block's CSS margins: `.md h2 { margin: 14px 0 4px }`, `.md p` and `.md ol, .md ul { margin: 0 0 8px }`;
    /// code and quotes as paragraphs, a rule 8 pt either side (no board draws those).
    static func margins(of block: MarkdownBlocks.Block) -> (top: CGFloat, bottom: CGFloat) {
        switch block {
        case .heading: (headingTop, Spacing.xs)
        case .rule: (Spacing.s, Spacing.s)
        case .paragraph, .list, .code, .quote: (0, Spacing.s)
        }
    }

    /// The space above `next`: nothing above the first block (the board's `margin-top: 0` on the first heading),
    /// else the collapsed margin, the larger of `previous`'s bottom and `next`'s top.
    static func gap(after previous: MarkdownBlocks.Block?, before next: MarkdownBlocks.Block) -> CGFloat {
        guard let previous else { return 0 }
        return max(margins(of: previous).bottom, margins(of: next).top)
    }

    // MARK: - Markers and escapes

    /// `1.`, `2.` for the top level of a numbered list, `•` for bullets and `◦` for nested items.
    nonisolated static func markers(ordered: Bool, start: Int, items: [MarkdownBlocks.Item]) -> [String] {
        var number = start
        return items.map { item in
            guard item.depth == 0 else { return "◦" }
            guard ordered else { return "•" }
            defer { number += 1 }
            return "\(number)."
        }
    }

    /// Every `‹U+XXXX›` of a fenced code block on the warning tint (Contents board: `background: var(--warn-tint)`).
    static func escapesMarked(_ source: AttributedString) -> AttributedString {
        var text = source
        for range in escapeRanges(in: text) {
            text[range].backgroundColor = Color.statusWarningTint
        }
        return text
    }

    /// The ranges of the shown escapes, `‹U+` to the next `›`.
    static func escapeRanges(in text: AttributedString) -> [Range<AttributedString.Index>] {
        var ranges: [Range<AttributedString.Index>] = []
        var cursor = text.startIndex
        while let open = text[cursor...].range(of: "‹U+"),
            let close = text[open.upperBound...].range(of: "›")
        {
            ranges.append(open.lowerBound..<close.upperBound)
            cursor = close.upperBound
        }
        return ranges
    }
}
