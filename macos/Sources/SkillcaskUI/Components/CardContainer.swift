import SkillcaskDomain
import SwiftUI

/// An Overview card (Overview, Overview-States and Components boards, `.card`): the card surface with a 1 pt
/// border inside `Radius.l`, 12/14 padding, a `CardHeader` and, unless collapsed, the body `Spacing.s` below it.
/// No shadow in either appearance: the Tokens board's `elev.1` is "card: border only" and dark cards are "lighter
/// than ground, no shadow".
///
/// Only an error card takes the status colour on its border ("The card border takes the status colour only for
/// error; warning and update stay on the dot so a healthy project is visually quiet"); every other severity, and
/// no severity, keeps `Color.separator`. `isCollapsed` is the Healthy state's one-line mode: the header alone,
/// the body not built. The border is a `strokeBorder` so the hairline stays inside the shape. The card takes the
/// width and height it is offered, content at the top left, so a row of cards stretches both to the taller one
/// as the boards' CSS grid does; a stack that should not stretch its cards wraps them in
/// `fixedSize(horizontal: false, vertical: true)`.
///
/// Drawn with tokens rather than a system `GroupBox`: `GroupBox` on macOS paints its own material, border and
/// corner radius that none of the token values can reach, and the board's card is a surface, not a control. The
/// card bodies (doctor lines, the sources table, policy rows) are the screen's; this is the frame.
public struct CardContainer<Accessory: View, Content: View>: View {
    public let title: String
    /// What follows the title after the middle dot: `2 problems`, `none`, `all good`.
    public let status: String?
    /// The header dot and, for `.error` only, the border colour; nil draws no dot (Sources, Policy, Agents).
    public let severity: Severity?
    /// The quiet trailing text of the header: `8 checks passed`.
    public let summary: String?
    /// The Healthy state's one-line mode: header only, no body.
    public let isCollapsed: Bool
    public let onTitleTap: (() -> Void)?
    private let accessory: Accessory
    private let content: Content

    public init(
        title: String, status: String? = nil, severity: Severity? = nil, summary: String? = nil,
        isCollapsed: Bool = false, onTitleTap: (() -> Void)? = nil, @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.status = status
        self.severity = severity
        self.summary = summary
        self.isCollapsed = isCollapsed
        self.onTitleTap = onTitleTap
        self.accessory = accessory()
        self.content = content()
    }

    /// The rule: the error dot colour on an error card, the separator on every other card.
    nonisolated public static func borderColor(for severity: Severity?) -> Color {
        severity == .error ? Color.statusDot(.error) : .separator
    }

    /// Whether the body is built: never in the collapsed one-line mode.
    public var showsBody: Bool { !isCollapsed }

    /// The border this card draws.
    public var borderColor: Color { Self.borderColor(for: severity) }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            CardHeader(
                title: title, status: status, severity: severity, summary: summary, onTitleTap: onTitleTap
            ) {
                accessory
            }
            if showsBody {
                content
            }
        }
        // Debug builds only: records the widths each card is measured at (`OverviewLayoutCostTests`).
        .measureProbe()
        .padding(.vertical, Size.cardPaddingV)
        .padding(.horizontal, Size.cardPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surfaceCard, in: shape)
        .overlay(shape.strokeBorder(borderColor, lineWidth: Size.hairline))
    }

    // MARK: - Derived

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Radius.l)
    }
}

extension CardContainer where Accessory == EmptyView {
    /// A card whose header carries no accessory.
    public init(
        title: String, status: String? = nil, severity: Severity? = nil, summary: String? = nil,
        isCollapsed: Bool = false, onTitleTap: (() -> Void)? = nil, @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title, status: status, severity: severity, summary: summary, isCollapsed: isCollapsed,
            onTitleTap: onTitleTap, accessory: { EmptyView() }, content: content)
    }
}

#Preview("CardContainer, light") {
    VStack(spacing: Spacing.cardGap) {
        CardContainer(title: "Health", status: "2 problems", severity: .error, onTitleTap: openList) {
            Button("Repair") {}.controlSize(.small)
        } content: {
            Text("6 checks passed").font(Font.Token.callout).foregroundStyle(Color.textSecondary)
        }
        CardContainer(title: "Updates", status: "2 available", severity: .update) {
            Text("pdf 1.2.0 → 1.4.0").font(Font.Token.callout).foregroundStyle(Color.textPrimary)
        }
        CardContainer(title: "Health", status: "all good", severity: .ok, summary: "8 checks passed", isCollapsed: true)
        {
            Text("hidden")
        }
    }
    .padding(Spacing.l)
    .background(Color.surfaceGrouped)
}

#Preview("CardContainer, dark") {
    VStack(spacing: Spacing.cardGap) {
        CardContainer(title: "Health", status: "2 problems", severity: .error, onTitleTap: openList) {
            Button("Repair") {}.controlSize(.small)
        } content: {
            Text("6 checks passed").font(Font.Token.callout).foregroundStyle(Color.textSecondary)
        }
        CardContainer(title: "Updates", status: "2 available", severity: .update) {
            Text("pdf 1.2.0 → 1.4.0").font(Font.Token.callout).foregroundStyle(Color.textPrimary)
        }
        CardContainer(title: "Health", status: "all good", severity: .ok, summary: "8 checks passed", isCollapsed: true)
        {
            Text("hidden")
        }
    }
    .padding(Spacing.l)
    .background(Color.surfaceGrouped)
    .preferredColorScheme(.dark)
}

/// The title tap of a sample card: the screen opens the filtered list, a sample does nothing.
private func openList() {}
