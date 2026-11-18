import SkillcaskDomain
import SwiftUI

/// A one-line status-tinted message (Components "Progress block, toast, banners", List-States, Overview-States,
/// Contents, Detail-States): a symbol in the status text colour, an optional bold lead, the sentence, and at most
/// one trailing control. The lighter sibling of `FailureBanner`: no title row, no action row, no dismissal of its
/// own. The text wraps when the column is too narrow for one line.
///
/// Three densities, one per board: `.banner` is the Components callout (the not-managed banner), `.strip` the
/// Detail-States and Contents line under a header, `.compact` the List-States offline line in the list header.
public struct MessageStrip: View {
    /// What the strip reports; decides the tint, the text colour of the symbol and link, and the default symbol.
    public enum Kind: Hashable, Sendable, CaseIterable {
        /// Grey: an explanation, not a problem (Detail-States "Dependency").
        case neutral
        /// Green: nothing to do (Versions-States "Up to date").
        case ok
        /// Blue: offline, details unavailable.
        case info
        /// Amber: not managed, abandoned, invisible characters.
        case warning
        /// Red: a failure that needs no action row.
        case error

        /// The severity whose tint and text colour the strip draws.
        public var severity: Severity {
            switch self {
            case .neutral: .neutral
            case .ok: .ok
            case .info: .update
            case .warning: .warning
            case .error: .error
            }
        }
    }

    /// How much room the strip takes.
    public enum Density: Hashable, Sendable {
        /// Components `.callout`: 10/12 padding, 16 pt symbol, 13 pt semibold lead, 12 pt sentence.
        case banner
        /// Detail-States `.cal` and the Contents strip: 8/12 padding, 14 pt symbol, 12 pt sentence.
        case strip
        /// List-States offline: 6/8 padding, radius 6, 12 pt symbol, 11 pt sentence.
        case compact
        /// Adopt-States sheet strip: 8/10 padding, radius 8, 14 pt symbol, 8 pt gap, 12 pt sentence.
        case sheet
    }

    /// The Adopt-States strip's symbol (`svg width="14"`); no 14 pt icon token exists.
    nonisolated static let sheetIconSize: CGFloat = 14

    /// The one control a strip may end with.
    public enum Trailing {
        /// The board's `.btn.sm`: the system small bordered button (Review, Retry, Add acme/lint2…).
        case button(String, action: () -> Void)
        /// A semibold link in the status text colour (Contents' See Security).
        case link(String, action: () -> Void)
        /// A medium-weight Iris link (Detail-States dependency strip's "Show caveman"), whatever the strip's kind.
        case accentLink(String, action: () -> Void)

        /// The control's words.
        public var title: String {
            switch self {
            case .button(let title, _), .link(let title, _), .accentLink(let title, _): title
            }
        }
    }

    /// The symbol of an info strip (Components, List-States, Detail-States offline).
    nonisolated static let infoSymbol = FailureBanner.infoSymbol
    /// The symbol of an ok strip; the Versions-States board draws none, a strip always leads with one.
    nonisolated static let okSymbol = "checkmark.circle"
    /// The symbol of a warning strip (Components, Overview-States not managed).
    nonisolated static let warningSymbol = FailureBanner.warningSymbol
    /// The symbol of an error strip (Components).
    nonisolated static let errorSymbol = FailureBanner.errorSymbol
    /// The crossed-out eye of the Contents invisible-character strip.
    public nonisolated static let invisibleSymbol = "eye.slash"
    /// The archive box of the Detail-States abandoned strip.
    public nonisolated static let abandonedSymbol = "archivebox"
    /// The hourglass of the Versions cooldown callout.
    public nonisolated static let cooldownSymbol = "hourglass"
    /// The crossed-out tag of the Versions-States tag-moved callout.
    public nonisolated static let tagMovedSymbol = "tag.slash"

    private let kind: Kind
    private let title: String?
    private let text: String
    private let monoFragment: String?
    private let emphasis: String?
    private let symbol: String
    private let density: Density
    private let trailing: Trailing?

    /// - Parameters:
    ///   - kind: The tint and text colour.
    ///   - title: The bold lead before `text` (`Offline.`, `12 skills on this Mac are not managed yet.`).
    ///   - text: The sentence, from `StripCopy`.
    ///   - monoFragment: The first occurrence in `text` drawn in mono (`‹U+202E›`, `acme/lint2`).
    ///   - emphasis: The first occurrence in `text` drawn semibold (`caveman` in the dependency strip); ignored
    ///     when `monoFragment` is set.
    ///   - symbol: An SF Symbol replacing the kind's default (`invisibleSymbol`, `abandonedSymbol`,
    ///     `cooldownSymbol`, `tagMovedSymbol`); nil keeps the default.
    ///   - density: Which board's proportions.
    ///   - trailing: The one control at the trailing end; nil when the board draws none.
    public init(
        _ kind: Kind, title: String? = nil, text: String, monoFragment: String? = nil, emphasis: String? = nil,
        symbol: String? = nil, density: Density = .banner, trailing: Trailing? = nil
    ) {
        self.kind = kind
        self.title = title
        self.text = text
        self.monoFragment = monoFragment
        self.emphasis = emphasis
        self.symbol = symbol ?? Self.symbol(for: kind)
        self.density = density
        self.trailing = trailing
    }

    /// The kind's default symbol, as the Components board draws it.
    nonisolated static func symbol(for kind: Kind) -> String {
        switch kind {
        case .neutral, .info: infoSymbol
        case .ok: okSymbol
        case .warning: warningSymbol
        case .error: errorSymbol
        }
    }

    /// The trailing control's title, or nil when the strip has none: a control needs words to be drawn.
    var trailingTitle: String? {
        guard let title = trailing?.title, !title.isEmpty else { return nil }
        return title
    }

    public var body: some View {
        HStack(alignment: .center, spacing: gap) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            label
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if trailingTitle != nil, let trailing {
                control(trailing)
            }
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(Color.statusTint(kind.severity), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Subviews

    private var statusColor: Color { Color.statusText(kind.severity) }

    private var label: Text {
        let sentence = styledSentence
        guard let title, !title.isEmpty else { return sentence }
        return Text(title).font(titleFont) + Text(" ").font(bodyFont) + sentence
    }

    /// The sentence with its mono fragment, or else its semibold emphasis.
    private var styledSentence: Text {
        guard monoFragment == nil, let emphasis, !emphasis.isEmpty, let range = text.range(of: emphasis) else {
            return FailureBanner.styled(text, fragment: monoFragment, font: bodyFont)
        }
        return Text(text[..<range.lowerBound]).font(bodyFont)
            + Text(text[range]).font(titleFont)
            + Text(text[range.upperBound...]).font(bodyFont)
    }

    @ViewBuilder
    private func control(_ trailing: Trailing) -> some View {
        switch trailing {
        case .button(let title, let action):
            // The board's `.btn.sm` (22 pt) is the system small bordered button, 20 pt in AppKit (as FailureBanner).
            Button(title, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .link(let title, let action):
            Button(action: action) {
                Text(title)
                    .font(Font.Token.calloutSemibold)
                    .foregroundStyle(statusColor)
            }
            .buttonStyle(.plain)
        case .accentLink(let title, let action):
            Button(action: action) {
                Text(title)
                    .font(Font.Token.calloutMedium)
                    .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Metrics

    private var bodyFont: Font {
        density == .compact ? Font.Token.caption : Font.Token.callout
    }

    /// Components draws the lead at 13 pt semibold; the denser strips keep it at the sentence size.
    private var titleFont: Font {
        switch density {
        case .banner: Font.Token.bodyEmphasis
        case .strip, .sheet: Font.Token.calloutSemibold
        case .compact: Font.Token.captionSemibold
        }
    }

    /// 16 pt on Components; the boards' 14 pt has no token, so the toolbar size (13) stands, as on the toast.
    private var iconSize: CGFloat {
        switch density {
        case .banner: Size.iconSidebar
        case .strip: Size.iconToolbar
        case .compact: Size.iconInline
        case .sheet: Self.sheetIconSize
        }
    }

    private var gap: CGFloat {
        density == .compact || density == .sheet ? Spacing.s : Spacing.rowGap
    }

    private var verticalPadding: CGFloat {
        switch density {
        case .banner: Spacing.cardGap
        case .strip, .sheet: Spacing.s
        case .compact: Spacing.inline
        }
    }

    private var horizontalPadding: CGFloat {
        switch density {
        case .compact: Spacing.s
        case .sheet: Spacing.cardGap
        case .banner, .strip: Spacing.m
        }
    }

    private var radius: CGFloat {
        density == .compact ? Radius.m : Radius.l
    }
}

#Preview("MessageStrip, light") {
    VStack(spacing: Spacing.s) {
        MessageStrip(
            .warning, title: StripCopy.notManagedTitle(count: 12), text: StripCopy.notManagedBody(count: 12),
            trailing: .button(StripCopy.review, action: {}))
        MessageStrip(.info, title: StripCopy.offlineTitle, text: StripCopy.offlineBody)
        MessageStrip(.info, text: StripCopy.offlineHeader, density: .compact)
    }
    .padding(Spacing.l)
    .frame(width: 520)
    .background(Color.surfaceWindow)
}

#Preview("MessageStrip, dark") {
    VStack(spacing: Spacing.s) {
        MessageStrip(
            .warning, title: StripCopy.notManagedTitle(count: 12), text: StripCopy.notManagedBody(count: 12),
            trailing: .button(StripCopy.review, action: {}))
        MessageStrip(.info, title: StripCopy.offlineTitle, text: StripCopy.offlineBody)
        MessageStrip(.info, text: StripCopy.offlineHeader, density: .compact)
    }
    .padding(Spacing.l)
    .frame(width: 520)
    .background(Color.surfaceWindow)
    .preferredColorScheme(.dark)
}
