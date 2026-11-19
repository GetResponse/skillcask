import AppKit
import SkillcaskDomain
import SwiftUI

/// The inline layer of a rendered SKILL.md block (Contents board `.md`): a block's Markdown source becomes the
/// attributed string `InlineText` lays out. `AttributedString(markdown:)` with `.inlineOnlyPreservingWhitespace`
/// parses emphasis, `code` and links, so line breaks inside a paragraph stay where the file has them. `code` runs
/// take `type.mono` and the `codeChip` mark; escaped invisible characters (`‹U+202E›`, D26) take the `escapeChip`
/// mark; links are drawn in the accent colour without their target (the text is the package's, and its link text
/// may not be where it points). Markdown the parser rejects is shown as written.
///
/// A chip's fill is drawn by `InlineText`'s layout manager, not by `.backgroundColor`, because the board pads it
/// (`.md code { padding: 1px 4px; border-radius: 3px }`) and an attribute background cannot. The horizontal padding
/// is reserved in the text as kerning on the character before the chip and on the chip's last character, so the
/// fill never overlaps a neighbour; a chip that opens a line takes it as indentation instead.
enum MarkdownInline {
    /// The text style and the fixed line box of a block.
    struct Style: Equatable {
        let scale: Font.Token.Scale
        let color: Color
        /// The line pitch every line of the block keeps, whatever its runs' fonts.
        let lineHeight: CGFloat

        /// `.md { font-size: 13px; line-height: 20px }`.
        static let body = Style(scale: .body, color: Color.textPrimary, lineHeight: MarkdownBody.lineHeight)
        /// `.md h2 { font-size: 15px; line-height: 20px; font-weight: 600 }`: `type.headline`.
        static let heading = Style(
            scale: .headline, color: Color.textPrimary, lineHeight: Font.Token.Scale.headline.lineHeight)
        /// `###` and deeper: no board draws them; the body size in semibold on the body's line.
        static let minorHeading = Style(
            scale: .bodyEmphasis, color: Color.textPrimary, lineHeight: MarkdownBody.lineHeight)
        /// A block quote: body text in the secondary colour.
        static let quote = Style(scale: .body, color: Color.textSecondary, lineHeight: MarkdownBody.lineHeight)

        var font: NSFont { .systemFont(ofSize: scale.size, weight: scale.appKitWeight) }
    }

    /// A run drawn on a padded rounded fill.
    enum Chip: CaseIterable {
        /// `code`: `.md code { background: var(--grouped); padding: 1px 4px; border-radius: 3px }`.
        case code
        /// An escaped invisible character: `background: var(--warn-tint); border-radius: 3px; padding: 0 2px`.
        case escape

        /// The attribute that marks the run; its value is `true`.
        var key: NSAttributedString.Key {
            switch self {
            case .code: NSAttributedString.Key("skillcask.markdown.code")
            case .escape: NSAttributedString.Key("skillcask.markdown.escape")
            }
        }

        var fill: Color {
            switch self {
            case .code: Color.surfaceGrouped
            case .escape: Color.statusWarningTint
            }
        }

        var paddingH: CGFloat {
            switch self {
            case .code: Spacing.xs
            case .escape: MarkdownInline.escapePaddingH
            }
        }

        var paddingV: CGFloat {
            switch self {
            case .code: Size.hairline
            case .escape: 0
            }
        }

        /// Both boards round the chip by 3 px, between `radius.s` (4) and none.
        var radius: CGFloat { MarkdownInline.chipRadius }
    }

    // MARK: - Board values

    /// `border-radius: 3px` on `code` and on the escape mark.
    static let chipRadius: CGFloat = 3
    /// The escape mark's `padding: 0 2px`.
    static let escapePaddingH: CGFloat = 2
    /// `type.mono` for `code`.
    static var codeFont: NSFont {
        .monospacedSystemFont(ofSize: Font.Token.Scale.mono.size, weight: Font.Token.Scale.mono.appKitWeight)
    }

    // MARK: - Building

    /// One paragraph, heading or quote: the inline runs, the chips' padding and the block's line box.
    static func block(_ source: String, style: Style) -> NSAttributedString {
        let text = runs(source, style: style)
        reserveChipPadding(in: text)
        applyParagraph(to: text, style: style, indent: 0, markerEnd: nil)
        return text
    }

    /// A list as one text: an item per paragraph, `\t1.\t` before it so the marker ends `MarkdownBody.markerGap`
    /// short of the item's column (`.md ol { padding-left: 22px }`, one column more per level); wrapped lines and
    /// the item's own line breaks hang at that column.
    static func list(ordered: Bool, start: Int, items: [MarkdownBlocks.Item], style: Style) -> NSAttributedString {
        let markers = MarkdownBody.markers(ordered: ordered, start: start, items: items)
        let result = NSMutableAttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .font: style.font, .foregroundColor: NSColor(Color.textSecondary),
            ]
            let line = NSMutableAttributedString(string: "\t" + markers[index] + "\t", attributes: markerAttributes)
            // A line separator keeps the item one paragraph, so its continuation lines hang at the column.
            let content = runs(item.text.replacingOccurrences(of: "\n", with: "\u{2028}"), style: style)
            reserveChipPadding(in: content)
            line.append(content)
            let column = CGFloat(item.depth + 1) * MarkdownBody.listIndent
            applyParagraph(
                to: line, style: style, indent: column, markerEnd: column - MarkdownBody.markerGap,
                chipFirst: startsWithChip(content))
            result.append(line)
        }
        return result
    }

    /// The styled runs of `source` before any layout attribute.
    static func runs(_ source: String, style: Style) -> NSMutableAttributedString {
        let shown = DiffCopy.shown(source)
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed = (try? AttributedString(markdown: shown, options: options)) ?? AttributedString(shown)
        let result = NSMutableAttributedString()
        let color = NSColor(style.color)
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if intent.contains(.code) {
                attributes[.font] = codeFont
                attributes[Chip.code.key] = true
            } else {
                attributes[.font] = font(
                    style.font, bold: intent.contains(.stronglyEmphasized),
                    italic: intent.contains(.emphasized))
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.link != nil {
                attributes[.foregroundColor] = NSColor(Color.accent)
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        for range in escapeRanges(in: result.string) {
            result.addAttribute(Chip.escape.key, value: true, range: range)
        }
        return result
    }

    /// The ranges of the shown escapes, `‹U+` to the next `›`, in UTF-16 offsets.
    static func escapeRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = text.startIndex
        while let open = text[cursor...].range(of: "‹U+"), let close = text[open.upperBound...].range(of: "›") {
            ranges.append(NSRange(open.lowerBound..<close.upperBound, in: text))
            cursor = close.upperBound
        }
        return ranges
    }

    /// The ranges `chip` marks in `text`.
    static func ranges(of chip: Chip, in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(chip.key, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil {
                ranges.append(range)
            }
        }
        return ranges
    }

    // MARK: - Layout attributes

    /// Kerning for the chips' horizontal padding: on the character before a chip (unless a line break or the
    /// start, where `applyParagraph` indents instead) and on the chip's last character.
    private static func reserveChipPadding(in text: NSMutableAttributedString) {
        let string = text.string as NSString
        for chip in Chip.allCases {
            for range in ranges(of: chip, in: text) {
                if range.location > 0, !isLineBreak(string.character(at: range.location - 1)) {
                    addKern(chip.paddingH, at: range.location - 1, in: text)
                }
                addKern(chip.paddingH, at: NSMaxRange(range) - 1, in: text)
            }
        }
    }

    private static func addKern(_ amount: CGFloat, at index: Int, in text: NSMutableAttributedString) {
        let current = text.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
        text.addAttribute(.kern, value: current + amount, range: NSRange(location: index, length: 1))
    }

    private static func isLineBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x2028
    }

    /// The padding a chip opening the text needs before it, 0 when the text opens with plain text.
    private static func startsWithChip(_ text: NSAttributedString) -> CGFloat {
        guard text.length > 0 else { return 0 }
        return Chip.allCases.filter { text.attribute($0.key, at: 0, effectiveRange: nil) != nil }
            .map(\.paddingH).max() ?? 0
    }

    /// The block's paragraph style on every paragraph: the line box (`InlineText` centres the baseline in it),
    /// word wrapping, the hanging indent and marker tab of a list item, and the indentation of a paragraph that
    /// opens with a chip.
    private static func applyParagraph(
        to text: NSMutableAttributedString, style: Style, indent: CGFloat, markerEnd: CGFloat?, chipFirst: CGFloat = 0
    ) {
        let whole = NSRange(location: 0, length: text.length)
        let string = text.string as NSString
        string.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) {
            _, range, enclosing, _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = style.lineHeight
            paragraph.maximumLineHeight = style.lineHeight
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.headIndent = indent
            if let markerEnd {
                paragraph.tabStops = [
                    NSTextTab(textAlignment: .right, location: markerEnd),
                    NSTextTab(textAlignment: .left, location: indent + chipFirst),
                ]
                paragraph.firstLineHeadIndent = 0
            } else {
                paragraph.tabStops = []
                let opener = range.length > 0 ? startsWithChip(text.attributedSubstring(from: range)) : 0
                paragraph.firstLineHeadIndent = indent + opener
            }
            text.addAttribute(.paragraphStyle, value: paragraph, range: enclosing)
        }
    }

    private static func font(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var font = base
        let manager = NSFontManager.shared
        if bold {
            font = manager.convert(font, toHaveTrait: .boldFontMask)
        }
        if italic {
            font = manager.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }
}

extension Font.Token.Scale {
    /// The AppKit weight of the scale entry, for text laid out by TextKit (`InlineText`).
    var appKitWeight: NSFont.Weight {
        switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
    }
}
