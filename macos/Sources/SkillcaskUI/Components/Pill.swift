import SkillcaskDomain
import SwiftUI

/// The kind pill (Components board, "Source pill"): 16 pt tall (`Size.pill`), `Radius.s`, `pillFill` behind
/// `pillText` in `captionMedium`, with an SF Symbol before the name for a source. `.mono` is the reach chip of a
/// Security chip group (`Size.reachChip`, `monoSmall`); `.agent` is the 22 pt variant (`Size.pillLarge`,
/// `calloutMedium`) of a detail or Overview header ("Claude Code"); `.blocked` draws a blocked source on the
/// warning tint. Which kind a row has is Domain's `SourceKind`; this view only picks a glyph and a label.
public struct Pill: View {
    /// The variants the boards show.
    public enum Style: Hashable, Sendable {
        /// A plain word: "Project", "Local", "docx".
        case plain
        /// Where a package comes from: an SF Symbol then the name.
        case source(symbol: String)
        /// A command, host, path, variable or script, in SF Mono.
        case mono
        /// The header pill naming an agent, 22 pt tall.
        case agent
        /// A source the policy blocks: warning tint and text, an SF Symbol then the name.
        case blocked(symbol: String)
        /// The selected item among plain pills: Iris on the soft accent (Main board "pdf · installed").
        case accent
        /// A skill row's agent badge (`AgentBadges`): a monogram or a glyph, compact padding. A broken link adds
        /// the warning glyph before it, strikes the monogram through and takes the warning tint, so it reads
        /// without colour and on a selected row.
        case agentBadge(symbol: String?, isProblem: Bool)
    }

    /// The glyph before a broken agent badge.
    static let problemSymbol = "exclamationmark.triangle.fill"

    public let text: String
    public let style: Style

    /// Raised by a selected list row (`SkillRow`): the pill then draws white on translucent white.
    @Environment(\.backgroundProminence) private var prominence

    /// The boards' pill on a selected row, `#fff` on `rgba(255,255,255,0.22)`: not tokens (`macos/DESIGN.md` G5), the
    /// white every system accent carries.
    static let onSelectionText = Color.white
    static let onSelectionFill = Color.white.opacity(0.22)

    public init(_ text: String, style: Style = .plain) {
        self.text = text
        self.style = style
    }

    /// The pill of a source: its board name and glyph.
    public init(source: SourceKind) {
        self.init(SourceCopy.label(source), style: Self.style(of: source))
    }

    /// The pill of a source the policy blocks ("GitHub · blocked").
    public init(blocked source: SourceKind) {
        self.init(SourceCopy.blocked(source), style: .blocked(symbol: "circle.slash"))
    }

    /// The glyph before a source's name; `nil` for the wordless "Project" and "Local" pills.
    nonisolated public static func symbol(of source: SourceKind) -> String? {
        switch source {
        case .packagist: "shippingbox"
        case .github: "circle.fill"
        case .git: "arrow.triangle.branch"
        case .skillsSh: "globe"
        case .custom: "rectangle"
        case .project, .local: nil
        }
    }

    /// The style a source draws in: `.source` with its glyph, or `.plain` when it has none.
    nonisolated public static func style(of source: SourceKind) -> Style {
        guard let symbol = symbol(of: source) else { return .plain }
        return .source(symbol: symbol)
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            if isProblem {
                Image(systemName: Self.problemSymbol)
                    .imageScale(.small)
            }
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
            }
            if !text.isEmpty {
                Text(text)
                    .strikethrough(isProblem)
            }
        }
        .font(font)
        .foregroundStyle(textColor)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, paddingH)
        .frame(minWidth: isBadge ? height : nil, minHeight: isBadge ? height : nil)
        .frame(height: isBadge ? nil : height)
        .background(fill, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }

    // MARK: - Derived

    private var isBadge: Bool {
        if case .agentBadge = style { true } else { false }
    }

    private var isProblem: Bool {
        if case .agentBadge(_, true) = style { true } else { false }
    }

    private var symbol: String? {
        switch style {
        case .source(let symbol), .blocked(let symbol): symbol
        case .agentBadge(let symbol, _): symbol
        case .plain, .mono, .agent, .accent: nil
        }
    }

    private var font: Font {
        switch style {
        case .plain, .source, .blocked, .accent, .agentBadge: Font.Token.captionMedium
        case .mono: Font.Token.monoSmall
        case .agent: Font.Token.calloutMedium
        }
    }

    private var textColor: Color {
        switch style {
        case .blocked: Color.statusWarningText
        case .accent: Color.accent
        case .agentBadge(_, let isProblem) where prominence == .increased || !isProblem:
            prominence == .increased ? Self.onSelectionText : Color.pillText
        case .agentBadge: Color.statusWarningText
        case .plain, .source, .mono, .agent: prominence == .increased ? Self.onSelectionText : Color.pillText
        }
    }

    private var fill: Color {
        switch style {
        case .blocked: Color.statusWarningTint
        case .accent: Color.accentSoft
        case .agentBadge(_, let isProblem) where prominence == .increased || !isProblem:
            prominence == .increased ? Self.onSelectionFill : Color.pillFill
        case .agentBadge: Color.statusWarningTint
        case .plain, .source, .mono, .agent: prominence == .increased ? Self.onSelectionFill : Color.pillFill
        }
    }

    private var height: CGFloat {
        switch style {
        case .agent: Size.pillLarge
        case .mono: Size.reachChip
        case .plain, .source, .blocked, .accent, .agentBadge: Size.pill
        }
    }

    private var paddingH: CGFloat {
        switch style {
        case .agent: Spacing.s
        case .agentBadge: Spacing.xs
        case .plain, .source, .mono, .blocked, .accent: Spacing.inline
        }
    }
}

#Preview("Pill, light") {
    VStack(alignment: .leading, spacing: Spacing.s) {
        HStack(spacing: Spacing.s) {
            Pill(source: .packagist)
            Pill(source: .github)
            Pill(source: .git)
            Pill(source: .skillsSh)
            Pill(source: .custom("acme"))
            Pill(source: .project)
            Pill(source: .local)
            Pill(blocked: .github)
        }
        HStack(spacing: Spacing.xs) {
            Pill("pdftotext", style: .mono)
            Pill("qpdf", style: .mono)
            Pill("Claude Code", style: .agent)
        }
    }
    .padding(Spacing.l)
    .background(Color.surfaceWindow)
}

#Preview("Pill, dark") {
    VStack(alignment: .leading, spacing: Spacing.s) {
        HStack(spacing: Spacing.s) {
            Pill(source: .packagist)
            Pill(source: .github)
            Pill(source: .git)
            Pill(source: .skillsSh)
            Pill(source: .custom("acme"))
            Pill(source: .project)
            Pill(source: .local)
            Pill(blocked: .github)
        }
        HStack(spacing: Spacing.xs) {
            Pill("pdftotext", style: .mono)
            Pill("qpdf", style: .mono)
            Pill("Claude Code", style: .agent)
        }
    }
    .padding(Spacing.l)
    .background(Color.surfaceWindow)
    .preferredColorScheme(.dark)
}
