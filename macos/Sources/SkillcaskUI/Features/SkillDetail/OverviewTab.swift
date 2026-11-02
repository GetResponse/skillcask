import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The detail's Overview tab (Main board detail body, Detail-States): the strips of `OverviewContent` (dependency,
/// not managed, abandoned, offline) as `MessageStrip`s, the package card, the place card and the "Last checked"
/// footnote at the bottom. When the column is too short the body scrolls. A click on empty space calls
/// `onEmptyClick` (the detail returns to the Scope Overview).
///
/// Which rows each state shows is `OverviewContent.fields(for:)`, from the boards. Declared deviation: every state
/// draws its rows in the Main board's bordered card, where Detail-States' small panels draw a bare label/value
/// list; one card style keeps the tab one surface across states. The Main board's per-agent link table under
/// "Available to" is built from `status.targets` and `doctor`'s per-target link problems (`AgentIndex`).
struct OverviewTab: View {
    let content: OverviewContent
    let checkedAt: Date?
    /// Selects a requiring skill (the dependency strip's "Show caveman").
    var onShowSkill: (String) -> Void = { _ in }
    /// Opens Add Skill for the replacement of an abandoned package.
    var onAddReplacement: () -> Void = {}
    /// The abandoned strip's "Add <replacement>" is enabled (`ToolbarRules.canAddSkill`: no run in flight).
    var canAddReplacement = true
    /// Asks `info` again (the offline strip's Retry).
    var onRetry: () -> Void = {}
    /// Switches to the Security tab.
    var onSeeSecurity: () -> Void = {}
    /// Shows the Scope Overview, whose Health card lists the link problems (the agent hint's "See Health").
    var onSeeHealth: () -> Void = {}
    var onEmptyClick: () -> Void = {}

    @Environment(\.openURL) private var openURL

    /// The board's `.kv` label column, `grid-template-columns: 150px minmax(0,1fr)`.
    static let labelWidth: CGFloat = 150
    /// The board's `.kv > * { padding: 9px 0 }`; off the spacing scale, so named.
    static let rowPadding: CGFloat = 9
    /// The board's gap between the strip and the cards, `gap: 14px`; off the scale, so named.
    static let sectionGap: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .vertical) {
            column
            ScrollView { column }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Color.surfaceWindow
                .contentShape(Rectangle())
                .onTapGesture(perform: onEmptyClick)
        }
    }

    // MARK: - Subviews

    private var column: some View {
        VStack(alignment: .leading, spacing: Self.sectionGap) {
            ForEach(content.banners, id: \.self, content: banner)
            if !content.facts.isEmpty {
                card(content.facts)
            }
            if !content.place.isEmpty {
                card(content.place)
            }
            Spacer(minLength: 0)
            if let checkedAt {
                footnote(checkedAt)
            }
        }
        .padding(.horizontal, Size.columnPadding)
        .padding(.top, Spacing.l)
        .padding(.bottom, Size.columnPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func banner(_ banner: OverviewContent.Banner) -> some View {
        switch banner {
        case .offline:
            MessageStrip(
                .info, text: StripCopy.detailsOffline, density: .strip,
                trailing: .button(OutcomeCopy.retry, action: onRetry))
        case .abandoned(let replacement):
            MessageStrip(
                .warning, text: StripCopy.abandoned(replacement: replacement), monoFragment: replacement,
                symbol: MessageStrip.abandonedSymbol, density: .strip,
                trailing: replacement.map { .button(StripCopy.addReplacement($0), action: onAddReplacement) }
            )
            .disabled(!canAddReplacement)
        case .dependency(let skill, let requirers):
            MessageStrip(
                .neutral, text: DetailOverviewCopy.dependency(skill, requiredBy: requirers),
                emphasis: OutcomeCopy.list(requirers), density: .strip,
                trailing: requirers.first.map { first in
                    .accentLink(DetailOverviewCopy.show(first), action: { onShowSkill(first) })
                })
        case .notManaged(let spec):
            MessageStrip(
                .warning, text: DetailOverviewCopy.installedByAnotherTool(from: spec), monoFragment: spec,
                density: .strip)
        case .sourceUnknown:
            MessageStrip(
                .warning, title: DetailOverviewCopy.sourceUnknownTitle, text: DetailOverviewCopy.sourceUnknownBody,
                density: .strip)
        }
    }

    /// The Main board's bordered card: `padding: 4px 14px`, a hairline between rows.
    private func card(_ rows: [OverviewContent.Row]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Color.separator)
                        .frame(height: Size.hairline)
                }
                GridRow {
                    Text(row.label)
                        .font(Font.Token.body)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                        .padding(.vertical, Self.rowPadding)
                    value(row.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Self.rowPadding)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Size.cardPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Color.separator, lineWidth: Size.hairline))
    }

    @ViewBuilder private func value(_ value: OverviewContent.Value) -> some View {
        switch value {
        case .text(let text, let mono):
            FailureBanner.styled(text, fragment: mono, font: Font.Token.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .quiet(let text):
            Text(text)
                .font(Font.Token.body)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .mono(let path):
            monoPath(path)
        case .link(let text, let url):
            link(text) { openURL(url) }
        case .skills(let installed, let others):
            FlowLayout(spacing: Spacing.inline) {
                ForEach(installed, id: \.self) { Pill(DetailOverviewCopy.installedSkill($0), style: .accent) }
                ForEach(others, id: \.self) { Pill($0) }
                Text(DetailOverviewCopy.addOthers)
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        case .folder(let path, let url):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.cardGap) {
                monoPath(path)
                link(DetailOverviewCopy.openFolder) { Workspace.revealFolder(url) }
            }
        case .agents(let reach):
            agentLines(reach)
        case .security(let severity, let text, let showsLink):
            HStack(alignment: .center, spacing: Spacing.cardGap) {
                StatusDot(severity)
                Text(text)
                    .font(Font.Token.body)
                    .foregroundStyle(Color.textPrimary)
                if showsLink {
                    link(DetailOverviewCopy.seeSecurity, action: onSeeSecurity)
                }
            }
        }
    }

    /// `Claude Code  .claude/skills  linked`: the agent, the directory it reads in mono and the link state, a broken
    /// one in the warning colour; the remedy hint below in caption.
    private func agentLines(_ reach: AgentReach) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.xs) {
                ForEach(reach.links) { link in
                    GridRow {
                        Text(AgentCopy.name(link.target))
                            .font(Font.Token.body)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                        Text(link.target.shownPath)
                            .font(Font.Token.mono)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: Spacing.xs) {
                            if link.state.isProblem {
                                Image(systemName: SkillRow.findingsSymbol)
                                    .accessibilityHidden(true)
                            }
                            Text(AgentCopy.state(link.state, readsStore: link.target.directory == nil))
                        }
                        .font(link.state.isProblem ? Font.Token.calloutMedium : Font.Token.callout)
                        .foregroundStyle(agentStateColor(link.state))
                        .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let hint = AgentCopy.hint(reach) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.inline) {
                    Text(hint.text)
                        .font(Font.Token.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hint.seeHealth {
                        Button(action: onSeeHealth) {
                            Text(AgentCopy.seeHealth)
                                .font(Font.Token.captionMedium)
                                .foregroundStyle(Color.accent)
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func agentStateColor(_ state: AgentReach.State) -> Color {
        switch state {
        case .missing, .wrong, .blocked, .storeLinkBroken, .storeBlocked: Color.statusWarningText
        case .notInstalled: Color.statusErrorText
        case .linked, .pending, .unknown: Color.textSecondary
        }
    }

    private func monoPath(_ path: String) -> some View {
        Text(path)
            .font(Font.Token.mono)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    /// The boards' accent text link (`color: var(--accent); font-weight: 500`).
    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font.Token.bodyMedium)
                .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    /// `Last checked 4 min ago from skills.lock. …`, `skills.lock` in mono (Main board).
    private func footnote(_ date: Date) -> some View {
        FailureBanner.styled(
            DetailOverviewCopy.lastChecked(date), fragment: DetailOverviewCopy.lockFile, font: Font.Token.caption
        )
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
