import SkillcaskDomain
import SwiftUI

/// One row of the skills list (Main and Components boards, "Skill row"): the status dot, the name with its version
/// in mono, a second line saying where the skill comes from (`SkillRowSecondary`) and a trailing slot that says
/// exactly one thing (`SkillRowTrailing`). 52 pt tall (`Size.row`), one `Spacing.rowGap` between the parts.
///
/// Selection: inside a `List(selection:)` the system draws the accent highlight; the list passes `isSelected`
/// from the store's selection, and the row turns its text white and the source pill translucent whenever it is
/// selected in an active window (`usesSelectedStyle(isSelected:active:)`). `backgroundProminence` is not relied
/// on alone: it is not raised in every hosting (offscreen renders draw the accent but keep it `.standard`). In an
/// inactive window (`controlActiveState == .inactive`) the system's grey highlight carries the normal colours.
/// The row never paints a selection colour itself, so the highlight is always the system's. `accessory`, when
/// given, replaces the trailing slot (the list's hover controls). `isOffline` hides what only `outdated` knows. Stale while refreshing is not the row's: the boards fade
/// the whole list, selection included, so the list screen applies `staleOpacity` to its `List`.
public struct SkillRow: View {
    public let entry: SkillEntry
    public let isSelected: Bool
    public let isOffline: Bool
    /// The skills that require a dependency row (`ScopeSnapshot.requirerSkills(of:)`); nil or empty falls back to
    /// the `via` package names.
    public let requiredBy: [String]?
    /// Drawn in place of the trailing slot when set: the list row's hover controls (Components board, "hover with
    /// actions").
    public let accessory: AnyView?
    /// Which agents see the skill (`AgentIndex.reach(of:)`): badges under the trailing slot (or the hover
    /// controls) when `AgentReach.showsOnRow`, so they line up at the row's trailing edge on every row.
    public let agents: AgentReach

    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.controlActiveState) private var controlActiveState

    public init(
        _ entry: SkillEntry, isSelected: Bool = false, isOffline: Bool = false, requiredBy: [String]? = nil,
        accessory: AnyView? = nil, agents: AgentReach = .none
    ) {
        self.entry = entry
        self.isSelected = isSelected
        self.isOffline = isOffline
        self.requiredBy = requiredBy
        self.accessory = accessory
        self.agents = agents
    }

    /// The selected-row rule: white text and the translucent pill for a selected row in an active (key or main)
    /// window; an inactive window's grey highlight keeps the normal colours.
    nonisolated public static func usesSelectedStyle(isSelected: Bool, active: Bool) -> Bool {
        isSelected && active
    }

    /// The row height, `.row{height:52px}`.
    public static let height = Size.row
    /// "Stale while refreshing: rows at 50 % opacity" (List-States board): applied by the list screen to the whole
    /// list, so the selected row's accent fades with the rest.
    public static let staleOpacity: Double = 0.5
    /// The row's `padding: 0 12px 0 14px`: 14 before the dot is the card's horizontal padding token (the one 14 pt
    /// metric of the Tokens board), 12 after the trailing slot is `Spacing.m`.
    public static let leadingPadding = Size.cardPaddingH
    public static let trailingPadding = Spacing.m

    /// The boards' selected-row text, `#fff`, `rgba(255,255,255,0.82)` and the version's `opacity: 0.85`: not
    /// tokens (`macos/DESIGN.md` G5), the white that every system accent is designed to carry.
    static let selectedPrimary = Color.white
    static let selectedSecondary = Color.white.opacity(0.82)
    static let selectedVersion = Color.white.opacity(0.85)
    /// The ring around the dot of the selected row (`box-shadow: 0 0 0 2px rgba(255,255,255,0.35)`).
    static let selectedDotRing = Color.white.opacity(0.35)
    static let selectedDotRingWidth: CGFloat = 2

    /// The warning glyph before `N findings` (the boards' 12 pt triangle).
    static let findingsSymbol = "exclamationmark.triangle"

    public var body: some View {
        HStack(spacing: Spacing.rowGap) {
            dot
            column
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if let accessory {
                    accessory
                        .fixedSize()
                } else {
                    trailingSlot
                }
                if agents.showsOnRow {
                    AgentBadges(reach: agents)
                }
            }
            .layoutPriority(1)
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.trailingPadding)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Derived

    var trailing: SkillRowTrailing {
        .resolve(entry, offline: isOffline)
    }

    var secondary: SkillRowSecondary {
        .resolve(entry, requiredBy: requiredBy)
    }

    /// The second line as text, then which agents the skill is available to when the row draws badges:
    /// `anthropics/skills · GitHub; Available to Cursor; Claude Code link wrong`. The badges themselves are hidden
    /// from VoiceOver, since a row draws at most `AgentBadges.limit` of them.
    var accessibilityValue: String {
        agents.showsOnRow ? "\(secondary.text); \(AgentCopy.summary(agents))" : secondary.text
    }

    private var emphasized: Bool {
        Self.usesSelectedStyle(
            isSelected: isSelected || prominence == .increased, active: controlActiveState != .inactive)
    }

    private var primaryColor: Color {
        emphasized ? Self.selectedPrimary : Color.textPrimary
    }

    private var secondaryColor: Color {
        emphasized ? Self.selectedSecondary : Color.textSecondary
    }

    private var versionColor: Color {
        emphasized ? Self.selectedVersion : Color.textSecondary
    }

    private var statusColor: Color {
        if emphasized {
            return Self.selectedSecondary
        }
        return trailing.isQuiet ? Color.textSecondary : Color.statusText(trailing.severity)
    }

    // MARK: - Subviews

    private var dot: some View {
        StatusDot(trailing.severity)
            .background {
                if emphasized {
                    Circle()
                        .strokeBorder(Self.selectedDotRing, lineWidth: Self.selectedDotRingWidth)
                        .frame(
                            width: Size.statusDot + 2 * Self.selectedDotRingWidth,
                            height: Size.statusDot + 2 * Self.selectedDotRingWidth)
                }
            }
    }

    /// `flex: 1; min-width: 0`: takes what the dot and the trailing slot leave, and truncates its own text first.
    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.inline) {
                Text(entry.name)
                    .font(Font.Token.bodyEmphasis)
                    .foregroundStyle(primaryColor)
                if let version = entry.version {
                    Text(version)
                        .font(Font.Token.mono)
                        .foregroundStyle(versionColor)
                }
            }
            .lineLimit(1)
            secondaryLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The location (or "Required by …") and the source pill; the text truncates first.
    @ViewBuilder private var secondaryLine: some View {
        switch secondary {
        case .location(let location, let source):
            HStack(spacing: Spacing.inline) {
                if let location {
                    Text(location)
                        .font(Font.Token.monoSmall)
                        .foregroundStyle(secondaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let source {
                    Pill(source: source)
                }
            }
        case .requiredBy(let names):
            Text(Labels.requiredBy(names))
                .font(Font.Token.caption)
                .foregroundStyle(secondaryColor)
                .lineLimit(1)
        }
    }

    /// Keeps its natural width (`layoutPriority`), so the column truncates before the slot ever does.
    @ViewBuilder private var trailingSlot: some View {
        Group {
            switch trailing {
            case .update:
                Text(trailing.label).font(Font.Token.monoSmall)
            case .findings:
                HStack(spacing: Spacing.xs) {
                    Image(systemName: Self.findingsSymbol)
                    Text(trailing.label)
                }
                .font(Font.Token.calloutMedium)
            case .dependency, .state:
                Text(trailing.label).font(trailing.isQuiet ? Font.Token.callout : Font.Token.calloutMedium)
            }
        }
        .foregroundStyle(statusColor)
        .lineLimit(1)
        .fixedSize()
        .layoutPriority(1)
    }
}

#Preview("SkillRow, light") {
    VStack(spacing: 0) {
        SkillRow(DesignFixtures.commitMessage)
        SkillRow(DesignFixtures.pdf)
        SkillRow(DesignFixtures.pdf, isSelected: true)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.m))
        SkillRow(DesignFixtures.myNotes)
        SkillRow(
            DesignFixtures.safeRefactor, requiredBy: DesignFixtures.api.requirerSkills(of: DesignFixtures.safeRefactor))
        SkillRow(DesignFixtures.deployChecklist)
        SkillRow(DesignFixtures.caveman, isOffline: true)
    }
    .frame(width: Size.listWidth)
    .padding(Spacing.s)
    .background(Color.surfaceWindow)
}

#Preview("SkillRow, dark") {
    VStack(spacing: 0) {
        SkillRow(DesignFixtures.commitMessage)
        SkillRow(DesignFixtures.pdf)
        SkillRow(DesignFixtures.pdf, isSelected: true)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: Radius.m))
        SkillRow(DesignFixtures.myNotes)
        SkillRow(
            DesignFixtures.safeRefactor, requiredBy: DesignFixtures.api.requirerSkills(of: DesignFixtures.safeRefactor))
        SkillRow(DesignFixtures.deployChecklist)
        SkillRow(DesignFixtures.caveman, isOffline: true)
    }
    .frame(width: Size.listWidth)
    .padding(Spacing.s)
    .background(Color.surfaceWindow)
    .preferredColorScheme(.dark)
}
