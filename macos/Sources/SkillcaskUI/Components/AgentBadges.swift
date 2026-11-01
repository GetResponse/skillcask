import SkillcaskDomain
import SwiftUI

/// The agent badges of a skill row (`AgentReach.showsOnRow`), drawn under the row's trailing slot so they form one
/// column at the row's trailing edge whatever the location's length or the hover controls: one `Pill` in the
/// `.agentBadge` style per target in `AgentTarget.displayOrder` (Claude Code, Codex, then the rest), a two-letter
/// monogram (`CC`, `Cx`) or a folder glyph for a path target, never a vendor logo. At most `limit` slots: with more
/// targets, `limit - 1` badges and `+N`. A broken link is never hidden behind `+N`: it takes the place of the last
/// healthy badge that would show, and the badges keep the display order (only when more links are broken than fit
/// are some of them cut, and `+N` counts them). Hidden from VoiceOver: the row reads `AgentCopy.summary` instead.
struct AgentBadges: View {
    let reach: AgentReach

    /// Slots a row shows, `+N` included.
    static let limit = 3

    /// The badges a row draws, in display order, and how many it leaves out.
    static func visible(_ reach: AgentReach, limit: Int = limit) -> (shown: [AgentReach.Link], hidden: Int) {
        let links = reach.links
        guard links.count > limit else { return (links, 0) }
        let shownCount = limit - 1
        var picked = Array(links.prefix(shownCount))
        // Each broken link that would be cut replaces the last healthy badge still shown.
        for problem in links.dropFirst(shownCount) where problem.state.isProblem {
            guard let healthy = picked.lastIndex(where: { !$0.state.isProblem }) else { break }
            picked.remove(at: healthy)
            picked.append(problem)
        }
        let ids = Set(picked.map(\.id))
        return (links.filter { ids.contains($0.id) }, links.count - shownCount)
    }

    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let (shown, hidden) = Self.visible(reach)
        HStack(spacing: Spacing.xs) {
            ForEach(shown) { link in
                Pill(
                    AgentCopy.monogram(link.target) ?? "",
                    style: .agentBadge(
                        symbol: AgentCopy.monogram(link.target) == nil ? AgentCopy.pathSymbol : nil,
                        isProblem: link.state.isProblem)
                )
                .help(AgentCopy.help(link))
            }
            if hidden > 0 {
                Text(AgentCopy.overflow(hidden))
                    .font(Font.Token.caption)
                    .foregroundStyle(prominence == .increased ? Pill.onSelectionText : Color.textSecondary)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}
