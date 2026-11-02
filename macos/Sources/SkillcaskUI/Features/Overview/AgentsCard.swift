import SkillcaskDomain
import SwiftUI

/// The Agents card (Overview): `status.targets` as agent, directory and where it was set, then how many skills
/// are linked into them and, from `doctor`, which agent has a wrong link. In a quiet project (Overview-States
/// Healthy) it is one `Claude Code  .claude/skills  skills.toml` line per agent.
struct AgentsCard: View {
    let snapshot: ScopeSnapshot
    /// The scope's `AgentIndex` (`ScopeStore.agentIndex`): targets with their directories, and each skill's links.
    let agents: AgentIndex
    /// Overview-States Healthy: the compact one-line form.
    let isCompact: Bool

    /// Agent, directory: `targets.entries` paired with `targets.dirs` by `AgentTarget.resolve` (the lists are not
    /// parallel: an agent that reads the store has no directory of its own and shows the store's), `~/` in the
    /// global scope.
    static func targets(_ agents: AgentIndex) -> [(agent: String, directory: String)] {
        agents.targets.map { (AgentCopy.name($0), $0.shownPath) }
    }

    /// The skills that have no links in the agent folders: not installed or not linked by `status`, or reported
    /// as not installed by `doctor` (whose per-target `link missing` lines Health lists). Sorted by name.
    static func unlinked(_ snapshot: ScopeSnapshot) -> [String] {
        let missing = snapshot.doctor?.missingSkills ?? []
        return snapshot.entries
            .filter { entry in
                switch entry.health {
                case .notInstalled, .notLinked: true
                default: missing.contains(entry.name)
                }
            }
            .map(\.name)
            .sorted()
    }

    /// `12 skills are linked into both. Not linked: jira-syntax, sql-review. One Claude Code link is wrong — see
    /// Health.` The linked count leaves out `unlinked`, so it agrees with doctor's missing links. Broken links are
    /// counted per agent with a directory of its own: a store agent has no link, and a broken store link (a
    /// project skill `not linked`) is already named under "Not linked", once, however many agents read the store.
    /// After a failed `doctor` the counts come from the document Health keeps (`AgentIndex.countedReaches`).
    static func footnote(_ snapshot: ScopeSnapshot, agents: AgentIndex) -> String {
        let unlinked = unlinked(snapshot)
        var sentences = [
            OverviewCopy.linked(skills: snapshot.entries.count - unlinked.count, agents: agents.targets.count)
        ]
        if !unlinked.isEmpty {
            sentences.append(OverviewCopy.notLinked(unlinked))
        }
        let reaches = agents.countedReaches(in: snapshot)
        for target in agents.targets where target.directory != nil {
            let states = reaches.compactMap { reach in
                reach.links.first {
                    $0.target == target && ($0.state == .missing || $0.state == .wrong || $0.state == .blocked)
                }?
                .state
            }
            if !states.isEmpty {
                sentences.append(OverviewCopy.brokenLinks(states, agent: AgentCopy.name(target)))
            }
        }
        return sentences.joined(separator: " ")
    }

    var body: some View {
        let targets = Self.targets(agents)
        let from = snapshot.targets?.from ?? ""
        CardContainer(title: OverviewCopy.agents, isCollapsed: targets.isEmpty) {
            if isCompact {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(targets, id: \.agent) { target in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            Text(target.agent)
                                .font(Font.Token.calloutMedium)
                                .foregroundStyle(Color.textPrimary)
                            Text(target.directory)
                                .font(Font.Token.monoSmall)
                                .foregroundStyle(Color.textSecondary)
                            Spacer(minLength: Spacing.s)
                            Text(from)
                                .font(Font.Token.monoSmall)
                                .foregroundStyle(Color.textPrimary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    CardTable(
                        headers: [OverviewCopy.agent, OverviewCopy.directory, OverviewCopy.setIn],
                        rows: targets.map { target in
                            [
                                .medium(target.agent), .monoSecondary(target.directory),
                                .mono(from),
                            ]
                        })
                    Text(Self.footnote(snapshot, agents: agents))
                        .font(Font.Token.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
