import Foundation

/// Fixed sizes from the Tokens board and the screen boards (`macos/DESIGN.md`, Tokens), in points.
public enum Size {
    // MARK: - Rows and chrome

    /// Skill row height (`.row{height:52px}`).
    public static let row: CGFloat = 52
    /// Sidebar row height.
    public static let sidebarRow: CGFloat = 30
    /// Sidebar row with a subtitle (project rows).
    public static let sidebarRowSubtitle: CGFloat = 40
    /// Unified title bar and toolbar.
    public static let toolbar: CGFloat = 52
    /// Horizontal padding of a column (detail, Overview header).
    public static let columnPadding: CGFloat = 24
    /// Vertical card padding ("card padding 12/14").
    public static let cardPaddingV: CGFloat = 12
    /// Horizontal card padding ("card padding 12/14").
    public static let cardPaddingH: CGFloat = 14

    // MARK: - Controls

    /// Filter chip height (capsule).
    public static let chip: CGFloat = 22
    /// Kind pill height (`Radius.s`).
    public static let pill: CGFloat = 16
    /// The taller pill of a detail header (`padding: 0 8px; font-size: 12px`).
    public static let pillLarge: CGFloat = 22
    /// The status dot, drawn, "the one custom-drawn element on a row".
    public static let statusDot: CGFloat = 8
    /// Count badge height and minimum width (capsule, 11 pt semibold).
    public static let badge: CGFloat = 18
    /// The chip-count badge variant (16 high, 10 pt).
    public static let badgeSmall: CGFloat = 16
    /// Push button height.
    public static let button: CGFloat = 24
    /// Small push button height (`.btn.sm`).
    public static let buttonSmall: CGFloat = 22
    /// Segmented tab height (system segmented `Picker`).
    public static let tab: CGFloat = 22
    /// Search field height (system `.searchable`).
    public static let search: CGFloat = 26
    /// Mini progress bar height (track `separator`, fill `accent`, `Radius.miniProgress`).
    public static let miniProgress: CGFloat = 3
    /// Reach chip height: the Security board's `.ch` (`height: 20px`) of a chip group. The Components board's
    /// `.pill.mono` draws 18; the Security tab is the only place chips live, so the screen board wins.
    public static let reachChip: CGFloat = 20
    /// The 1 pt stroke of chip borders, card borders and separators (`border: 1px solid`).
    public static let hairline: CGFloat = 1

    // MARK: - Icons (SF Symbols)

    /// Toolbar symbols, 13 pt medium.
    public static let iconToolbar: CGFloat = 13
    /// Sidebar symbols.
    public static let iconSidebar: CGFloat = 16
    /// Inline symbols.
    public static let iconInline: CGFloat = 12

    // MARK: - Window and columns (gap G9: at 960 pt the sidebar gives first)

    /// Minimum window width ("two columns that becomes one at the 960 pt minimum width").
    public static let windowMinWidth: CGFloat = 960
    /// Sidebar column ideal width.
    public static let sidebarWidth: CGFloat = 220
    /// Sidebar column minimum width.
    public static let sidebarMinWidth: CGFloat = 180
    /// Skills list column ideal width.
    public static let listWidth: CGFloat = 360
    /// Skills list column minimum width.
    public static let listMinWidth: CGFloat = 300
    /// Detail column minimum width.
    public static let detailMinWidth: CGFloat = 400
    /// The Review Update sheet, Update All too (ReviewUpdate board: `width: 960px; height: 700px`). The 592×352
    /// `.sheet` frames on ReviewUpdate-States and AddSkill-States are presentation-only state cards, not sizes.
    public static let reviewSheet = CGSize(width: 960, height: 700)
    /// The Add Skill sheet's minimum, and its size when nothing is remembered and no window is known (AddSkill
    /// board: `width: 900px; height: 660px`). The sheet is resizable (`SheetSizing`, gap G16).
    public static let addSkillSheet = CGSize(width: 900, height: 660)
    /// The largest the Add Skill sheet grows to; the screen's visible frame caps it further.
    public static let addSkillSheetMax = CGSize(width: 1600, height: 1100)
    /// The Adopt sheet, single and batch (Adopt-States board: `.sheet { width: 592px; height: 340px }`).
    public static let adoptSheet = CGSize(width: 592, height: 340)
    /// The Settings window's width (Settings boards: `.swin{width:600px}`); its height follows the tab.
    public static let settingsWidth: CGFloat = 600
    /// The right-aligned label column of a Settings row (`.fr{grid-template-columns:200px …}`).
    public static let settingsLabel: CGFloat = 200
    /// The remove column of Advanced's environment table (`<th style="width: 40px">`).
    public static let settingsRemoveColumn: CGFloat = 40
    /// One row of that table, header included (`td{padding:6px 8px}` around a 12 pt line, rounded up for the
    /// text field).
    public static let settingsTableRow: CGFloat = 28

    /// Every scalar size in the order above, for the token sheet and the tests (the sheet sizes are listed apart).
    public static let catalog: [(name: String, value: CGFloat)] = [
        ("row", row), ("sidebarRow", sidebarRow), ("sidebarRowSubtitle", sidebarRowSubtitle), ("toolbar", toolbar),
        ("columnPadding", columnPadding), ("cardPaddingV", cardPaddingV), ("cardPaddingH", cardPaddingH),
        ("chip", chip), ("pill", pill), ("pillLarge", pillLarge), ("statusDot", statusDot), ("badge", badge),
        ("badgeSmall", badgeSmall), ("button", button), ("buttonSmall", buttonSmall), ("tab", tab),
        ("search", search), ("miniProgress", miniProgress), ("reachChip", reachChip), ("hairline", hairline),
        ("iconToolbar", iconToolbar),
        ("iconSidebar", iconSidebar), ("iconInline", iconInline), ("windowMinWidth", windowMinWidth),
        ("sidebarWidth", sidebarWidth), ("sidebarMinWidth", sidebarMinWidth), ("listWidth", listWidth),
        ("listMinWidth", listMinWidth), ("detailMinWidth", detailMinWidth), ("settingsWidth", settingsWidth),
        ("settingsLabel", settingsLabel), ("settingsRemoveColumn", settingsRemoveColumn),
        ("settingsTableRow", settingsTableRow),
    ]
}
