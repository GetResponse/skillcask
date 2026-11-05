import AppKit
import SkillcaskDomain
import SwiftUI
import Testing

@testable import SkillcaskUI

/// Every token resolves to the hex `macos/DESIGN.md` states, in both appearances; the type scale and the
/// metrics carry the board's numbers. The expected values are copied here on purpose: a drift between the
/// document and the code fails loudly.
@Suite struct DesignTokensTests {
    /// `macos/DESIGN.md` Tokens, the G4 decision included, light then dark.
    static let expectedHex: [Color.Token: (light: String, dark: String)] = [
        .surfaceWindow: ("#FFFFFF", "#1E1E1E"),
        .surfaceSidebar: ("#F2F2F4", "#272729"),
        .surfaceGrouped: ("#F5F5F7", "#232325"),
        .surfaceCard: ("#FFFFFF", "#2A2A2C"),
        .surfaceHover: ("#F2F2F5", "#2A2A2D"),
        .separator: ("#E3E3E8", "#353538"),
        .separatorStrong: ("#D1D1D6", "#454549"),
        .textPrimary: ("#1D1D1F", "#F5F5F7"),
        .textSecondary: ("#5E5E63", "#A1A1A6"),
        .textTertiary: ("#8A8A8F", "#7C7C82"),
        .controlFill: ("#FFFFFF", "#333336"),
        .controlBorder: ("#CFCFD4", "#48484C"),
        .accent: ("#6D4AFF", "#8B74FF"),
        .accentSoft: ("#EEE9FF", "#2E2750"),
        .accentLine: ("#CFC3FF", "#4A3F86"),
        .statusOkDot: ("#34C759", "#30D158"),
        .statusOkText: ("#1B7A35", "#4CD964"),
        .statusOkTint: ("#E9F8EC", "#17301D"),
        .statusUpdateDot: ("#0A7AFF", "#409CFF"),
        .statusUpdateText: ("#0A5FCC", "#6EB2FF"),
        .statusUpdateTint: ("#E6F1FF", "#172A44"),
        .statusWarningDot: ("#F5A623", "#FFB340"),
        .statusWarningText: ("#8A5A00", "#FFC24A"),
        .statusWarningTint: ("#FFF5DF", "#3A2C10"),
        .statusErrorDot: ("#FF3B30", "#FF6961"),
        .statusErrorText: ("#C42B22", "#FF7B72"),
        .statusErrorTint: ("#FFECEA", "#3D1F1D"),
        .statusNeutralDot: ("#8E8E93", "#98989D"),
        .statusNeutralText: ("#5E5E63", "#A1A1A6"),
        .statusNeutralTint: ("#F0F0F2", "#2C2C2E"),
        .pillFill: ("#ECECF0", "#38383C"),
        .pillText: ("#3A3A3F", "#D5D5DA"),
        .skeleton: ("#E8E8EC", "#333336"),
        .selectionSoft: ("#DCE8FF", "#1E3A66"),
        .diffAdded: ("#E6F6EA", "#1B3323"),
        .diffRemoved: ("#FDE8E6", "#3B1F1F"),
        .diffRisk: ("#FFF0C2", "#3A2F10"),
        .diffInvisible: ("#F3E8FF", "#2E2444"),
        .badgeWarningText: ("#3B2600", "#3B2600"),
    ]

    /// The CSS custom property every board used for each token.
    static let expectedCSS: [Color.Token: String] = [
        .surfaceWindow: "--win", .surfaceSidebar: "--side", .surfaceGrouped: "--grouped", .surfaceCard: "--card",
        .surfaceHover: "--hover", .separator: "--sep", .separatorStrong: "--sep2", .textPrimary: "--text",
        .textSecondary: "--text2", .textTertiary: "--text3", .controlFill: "--ctrl", .controlBorder: "--ctrl-b",
        .accent: "--accent", .accentSoft: "--accent-soft", .accentLine: "--accent-line", .statusOkDot: "--ok",
        .statusOkText: "--ok-t",
        .statusOkTint: "--ok-tint", .statusUpdateDot: "--upd", .statusUpdateText: "--upd-t",
        .statusUpdateTint: "--upd-tint", .statusWarningDot: "--warn", .statusWarningText: "--warn-t",
        .statusWarningTint: "--warn-tint", .statusErrorDot: "--err", .statusErrorText: "--err-t",
        .statusErrorTint: "--err-tint", .statusNeutralDot: "--neu", .statusNeutralText: "--neu-t",
        .statusNeutralTint: "--neu-tint", .pillFill: "--pill", .pillText: "--pill-t", .skeleton: "--skel",
        .selectionSoft: "--sel-soft", .diffAdded: "--diff-add", .diffRemoved: "--diff-del",
        .diffRisk: "--diff-risk", .diffInvisible: "--diff-inv", .badgeWarningText: "--badge-warn-t",
    ]

    /// Resolves `color` as AppKit would draw it under the named appearance, as `#RRGGBB` in 8-bit sRGB.
    @MainActor
    static func hex(of color: Color, under name: NSAppearance.Name) throws -> String {
        let appearance = try #require(NSAppearance(named: name))
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
            let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            hex = channels.reduce("#") { $0 + String(format: "%02X", Int(($1 * 255).rounded())) }
        }
        return hex
    }

    // MARK: - Colours

    @Test(arguments: Color.Token.allCases) @MainActor
    func tokenResolvesToTheBoardHexInBothAppearances(token: Color.Token) throws {
        let expected = try #require(Self.expectedHex[token])
        #expect(token.lightHex == expected.light && token.darkHex == expected.dark)
        #expect(try Self.hex(of: token.color, under: .aqua) == expected.light)
        #expect(try Self.hex(of: token.color, under: .darkAqua) == expected.dark)
        #expect(token.cssVariable == Self.expectedCSS[token])
    }

    @Test func catalogCoversEveryTokenOnce() {
        #expect(Color.Token.allCases.count == 39)
        #expect(Set(Self.expectedHex.keys) == Set(Color.Token.allCases))
        #expect(Set(Self.expectedCSS.keys) == Set(Color.Token.allCases))
        #expect(Set(Color.Token.allCases.map(\.cssVariable)).count == 39)
    }

    @Test @MainActor func staticColoursAreTheCatalogColours() throws {
        let statics: [(Color, Color.Token)] = [
            (.surfaceWindow, .surfaceWindow), (.surfaceSidebar, .surfaceSidebar), (.surfaceGrouped, .surfaceGrouped),
            (.surfaceCard, .surfaceCard), (.surfaceHover, .surfaceHover), (.separator, .separator),
            (.separatorStrong, .separatorStrong), (.textPrimary, .textPrimary), (.textSecondary, .textSecondary),
            (.textTertiary, .textTertiary), (.controlFill, .controlFill), (.controlBorder, .controlBorder),
            (.accent, .accent), (.accentSoft, .accentSoft), (.accentLine, .accentLine), (.statusOkDot, .statusOkDot),
            (.statusOkText, .statusOkText), (.statusOkTint, .statusOkTint), (.statusUpdateDot, .statusUpdateDot),
            (.statusUpdateText, .statusUpdateText), (.statusUpdateTint, .statusUpdateTint),
            (.statusWarningDot, .statusWarningDot), (.statusWarningText, .statusWarningText),
            (.statusWarningTint, .statusWarningTint), (.statusErrorDot, .statusErrorDot),
            (.statusErrorText, .statusErrorText), (.statusErrorTint, .statusErrorTint),
            (.statusNeutralDot, .statusNeutralDot), (.statusNeutralText, .statusNeutralText),
            (.statusNeutralTint, .statusNeutralTint), (.pillFill, .pillFill), (.pillText, .pillText),
            (.skeleton, .skeleton), (.selectionSoft, .selectionSoft), (.diffAdded, .diffAdded),
            (.diffRemoved, .diffRemoved), (.diffRisk, .diffRisk), (.diffInvisible, .diffInvisible),
            (.badgeWarningText, .badgeWarningText),
        ]
        #expect(statics.count == Color.Token.allCases.count)
        for (color, token) in statics {
            let expected = try #require(Self.expectedHex[token])
            #expect(try Self.hex(of: color, under: .aqua) == expected.light, "\(token)")
            #expect(try Self.hex(of: color, under: .darkAqua) == expected.dark, "\(token)")
        }
    }

    @Test @MainActor func severityHelpersPickTheStatusTokens() throws {
        let expected: [Severity: (dot: Color.Token, text: Color.Token, tint: Color.Token)] = [
            .neutral: (.statusNeutralDot, .statusNeutralText, .statusNeutralTint),
            .ok: (.statusOkDot, .statusOkText, .statusOkTint),
            .update: (.statusUpdateDot, .statusUpdateText, .statusUpdateTint),
            .warning: (.statusWarningDot, .statusWarningText, .statusWarningTint),
            .error: (.statusErrorDot, .statusErrorText, .statusErrorTint),
        ]
        for severity in Severity.allCases {
            let tokens = try #require(expected[severity])
            for scheme in [NSAppearance.Name.aqua, .darkAqua] {
                #expect(
                    try Self.hex(of: .statusDot(severity), under: scheme)
                        == Self.hex(of: tokens.dot.color, under: scheme))
                #expect(
                    try Self.hex(of: .statusText(severity), under: scheme)
                        == Self.hex(of: tokens.text.color, under: scheme))
                #expect(
                    try Self.hex(of: .statusTint(severity), under: scheme)
                        == Self.hex(of: tokens.tint.color, under: scheme))
            }
        }
    }

    @Test @MainActor func nearIdenticalGreysStayDistinct() throws {
        #expect(try Self.hex(of: .surfaceSidebar, under: .aqua) != Self.hex(of: .surfaceHover, under: .aqua))
        #expect(try Self.hex(of: .surfaceCard, under: .darkAqua) != Self.hex(of: .surfaceHover, under: .darkAqua))
        #expect(try Self.hex(of: .textSecondary, under: .aqua) == Self.hex(of: .statusNeutralText, under: .aqua))
        #expect(try Self.hex(of: .controlFill, under: .darkAqua) == Self.hex(of: .skeleton, under: .darkAqua))
    }

    // MARK: - Type

    @Test func typeScaleMatchesTheBoard() {
        let expected: [(Font.Token.Scale, CGFloat, CGFloat, Font.Weight, Font.Design)] = [
            (.title, 22, 28, .bold, .default),
            (.sheetTitle, 20, 26, .bold, .default),
            (.headline, 15, 20, .semibold, .default),
            (.body, 13, 18, .regular, .default),
            (.bodyEmphasis, 13, 18, .semibold, .default),
            (.bodyMedium, 13, 18, .medium, .default),
            (.callout, 12, 16, .regular, .default),
            (.calloutMedium, 12, 16, .medium, .default),
            (.calloutSemibold, 12, 16, .semibold, .default),
            (.caption, 11, 14, .regular, .default),
            (.captionMedium, 11, 14, .medium, .default),
            (.captionSemibold, 11, 14, .semibold, .default),
            (.mono, 12, 16, .regular, .monospaced),
            (.monoSmall, 11, 14, .regular, .monospaced),
        ]
        #expect(expected.map(\.0) == Font.Token.Scale.allCases)
        for (scale, size, lineHeight, weight, design) in expected {
            #expect(scale.size == size, "\(scale)")
            #expect(scale.lineHeight == lineHeight, "\(scale)")
            #expect(scale.weight == weight, "\(scale)")
            #expect(scale.design == design, "\(scale)")
            #expect(scale.font == Font.system(size: size, weight: weight, design: design), "\(scale)")
            #expect(scale.size >= 11, "nothing smaller than 11 pt exists")
        }
        #expect(
            Font.Token.title == Font.Token.Scale.title.font && Font.Token.monoSmall == Font.Token.Scale.monoSmall.font)
        #expect(Font.Token.bodyMedium == Font.Token.Scale.bodyMedium.font)
        #expect(Font.Token.sheetTitle == Font.Token.Scale.sheetTitle.font)
        #expect(Font.Token.captionSemibold == Font.Token.Scale.captionSemibold.font)
        #expect(Font.Token.calloutSemibold == Font.Token.Scale.calloutSemibold.font)
        #expect(Font.Token.titleTracking == -0.22)
        #expect(Font.Token.LineHeight.diff == 18)
    }

    // MARK: - Metrics

    @Test func spacingRadiiAndSizesMatchTheBoard() {
        #expect(
            [Spacing.xs, Spacing.s, Spacing.m, Spacing.l, Spacing.xl, Spacing.xxl, Spacing.xxxl] == [
                4, 8, 12, 16, 20, 24, 32,
            ])
        #expect(Spacing.cardGap == 10)
        #expect(Spacing.inline == 6)
        #expect(Spacing.rowGap == 10)
        #expect(Spacing.catalog.map(\.value) == [4, 8, 12, 16, 20, 24, 32, 10, 6, 10])
        #expect([Radius.s, Radius.m, Radius.l, Radius.xl, Radius.pill] == [4, 6, 8, 10, 999])
        #expect(Radius.miniProgress == 2)
        #expect(Radius.catalog.count == 6)
        let sizes: [(CGFloat, CGFloat)] = [
            (Size.row, 52), (Size.sidebarRow, 30), (Size.sidebarRowSubtitle, 40), (Size.toolbar, 52),
            (Size.columnPadding, 24), (Size.cardPaddingV, 12), (Size.cardPaddingH, 14), (Size.chip, 22),
            (Size.pill, 16), (Size.pillLarge, 22), (Size.statusDot, 8), (Size.badge, 18), (Size.badgeSmall, 16),
            (Size.button, 24), (Size.buttonSmall, 22), (Size.tab, 22), (Size.search, 26), (Size.miniProgress, 3),
            (Size.reachChip, 20), (Size.hairline, 1), (Size.iconToolbar, 13), (Size.iconSidebar, 16),
            (Size.iconInline, 12), (Size.windowMinWidth, 960),
            (Size.sidebarWidth, 220), (Size.sidebarMinWidth, 180), (Size.listWidth, 360), (Size.listMinWidth, 300),
            (Size.detailMinWidth, 400), (Size.settingsWidth, 600), (Size.settingsLabel, 200),
            (Size.settingsRemoveColumn, 40), (Size.settingsTableRow, 28),
        ]
        for (actual, expected) in sizes {
            #expect(actual == expected)
        }
        #expect(Size.catalog.map(\.value) == sizes.map(\.1))
        #expect(Size.reviewSheet == CGSize(width: 960, height: 700))
        #expect(Size.addSkillSheet == CGSize(width: 900, height: 660))
        #expect(Size.addSkillSheetMax == CGSize(width: 1600, height: 1100))
        #expect(Size.adoptSheet == CGSize(width: 592, height: 340))
        #expect(Size.sidebarMinWidth + Size.listMinWidth + Size.detailMinWidth <= Size.windowMinWidth)
    }
}
