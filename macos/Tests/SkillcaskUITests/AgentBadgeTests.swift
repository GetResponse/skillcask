import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The per-skill agent badges and the detail's per-agent lines over `DesignFixtures.agents` (a real 0.10.2 CLI
/// answer): what each row shows, what VoiceOver reads, which badges a row keeps, the hint, the Agents card.
@Suite @MainActor struct AgentBadgeTests {
    static let agents = DesignFixtures.agentIndex(DesignFixtures.agents)

    static func states(_ entry: SkillEntry, in index: AgentIndex = agents) -> [AgentReach.State] {
        index.reach(of: entry).links.map(\.state)
    }

    @Test func theAgentsFixtureCoversEveryState() throws {
        #expect(
            Self.agents.targets.map(\.shownPath) == [
                ".claude/skills", ".kiro/skills", ".agents/skills", "tools/skills",
            ])
        // Each reach lists Claude Code, Codex, then Kiro and the path target (`AgentTarget.displayOrder`).
        #expect(
            Self.agents.reach(of: DesignFixtures.agentsHandyNotes).links.map(\.target.entry) == [
                "claude", "codex", "kiro", "./tools/skills",
            ])
        #expect(Self.states(DesignFixtures.agentsHandyNotes) == [.linked, .linked, .linked, .linked])
        #expect(Self.states(DesignFixtures.agentsReviewNotes) == [.linked, .linked, .missing, .linked])
        #expect(Self.states(DesignFixtures.agentsSqlStyle) == [.wrong, .linked, .linked, .linked])
        #expect(Self.states(DesignFixtures.agentsReleaseChecklist) == [.linked, .linked, .linked, .blocked])
        #expect(
            Self.states(DesignFixtures.agentsNotes) == [
                .storeLinkBroken, .storeLinkBroken, .storeLinkBroken, .storeLinkBroken,
            ])
        #expect(
            Self.states(DesignFixtures.agentsJiraSyntax) == [
                .notInstalled, .notInstalled, .notInstalled, .notInstalled,
            ])
        let gone = try #require(DesignFixtures.agents.entry(id: "acme/gone"))
        #expect(Self.agents.reach(of: gone).links.isEmpty)
    }

    @Test func rowsDrawBadgesForTwoOrMoreTargetsOrABrokenLink() {
        let shown = { (snapshot: ScopeSnapshot) in
            let index = DesignFixtures.agentIndex(snapshot)
            return snapshot.entries.filter { index.reach(of: $0).showsOnRow }.map(\.name).sorted()
        }
        #expect(
            shown(DesignFixtures.agents) == ["handy-notes", "notes", "release-checklist", "review-notes", "sql-style"])
        #expect(shown(DesignFixtures.website).isEmpty, "one healthy target: the same badge on every row is noise")
        #expect(shown(DesignFixtures.websiteLinkMissing) == ["changelog"])
        let pending = DesignFixtures.agentIndex(DesignFixtures.agents, check: .pending)
        #expect(!pending.reach(of: DesignFixtures.agentsHandyNotes).showsOnRow, "no claim before doctor answers")
    }

    @Test func voiceOverReadsWhoTheSkillIsAvailableToAndWhatIsBroken() {
        #expect(
            AgentCopy.summary(Self.agents.reach(of: DesignFixtures.agentsReviewNotes))
                == "Available to Claude Code, Codex and ./tools/skills; Kiro link missing")
        #expect(
            AgentCopy.summary(Self.agents.reach(of: DesignFixtures.agentsNotes))
                == "Available to no agent; store link broken")
        let api = DesignFixtures.agentIndex(DesignFixtures.api)
        #expect(AgentCopy.summary(api.reach(of: DesignFixtures.pdf)) == "Available to Cursor; Claude Code link wrong")
        #expect(AgentCopy.summary(api.reach(of: DesignFixtures.commitMessage)) == "Available to Claude Code and Cursor")
    }

    @Test func theRowReadsItsAgentsInItsValue() {
        let api = DesignFixtures.agentIndex(DesignFixtures.api)
        let row = SkillRow(DesignFixtures.pdf, agents: api.reach(of: DesignFixtures.pdf))
        #expect(row.accessibilityValue == "anthropics/skills · GitHub; Available to Cursor; Claude Code link wrong")
        let website = DesignFixtures.website
        let commit = website.entries[0]
        let healthy = SkillRow(commit, agents: DesignFixtures.agentIndex(website).reach(of: commit))
        #expect(healthy.accessibilityValue == "acme/commit · Packagist", "a healthy single-target row reads no agents")
    }

    @Test func monogramsAreTextAndPathsUseAGlyph() {
        let target = { (entry: String) in AgentTarget(entry: entry, directory: nil) }
        #expect(AgentCopy.monogram(target("claude")) == "CC")
        #expect(AgentCopy.monogram(target("cursor")) == "Cu")
        #expect(AgentCopy.monogram(target("codex")) == "Cx")
        #expect(AgentCopy.monogram(target("devin")) == "De")
        #expect(AgentCopy.monogram(target("newagent")) == "Ne", "an unknown preset still gets two letters")
        #expect(AgentCopy.monogram(target("./tools/skills")) == nil)
        #expect(AgentCopy.name(target("./tools/skills")) == "./tools/skills")
        #expect(
            AgentCopy.help(AgentReach.Link(target: target("codex"), state: .linked))
                == "Codex · .agents/skills · installed")
        #expect(
            AgentCopy.help(
                AgentReach.Link(
                    target: AgentTarget(entry: "claude", directory: ".claude/skills", isGlobal: true), state: .wrong))
                == "Claude Code · ~/.claude/skills · link wrong")
    }

    @Test func aRowKeepsBrokenLinksAndCountsTheRest() {
        let shown = { (entry: SkillEntry) in AgentBadges.visible(Self.agents.reach(of: entry)).shown.map(\.target.entry)
        }
        #expect(shown(DesignFixtures.agentsHandyNotes) == ["claude", "codex"], "healthy: the priority agents")
        #expect(AgentBadges.visible(Self.agents.reach(of: DesignFixtures.agentsHandyNotes)).hidden == 2)
        // A problem that would be cut takes the last healthy slot; the order stays.
        #expect(shown(DesignFixtures.agentsReviewNotes) == ["claude", "kiro"], "Kiro's missing link is never in +N")
        #expect(shown(DesignFixtures.agentsReleaseChecklist) == ["claude", "./tools/skills"])
        // A problem already visible stays where it is.
        #expect(shown(DesignFixtures.agentsSqlStyle) == ["claude", "codex"])
        let target = { (entry: String) in AgentTarget(entry: entry, directory: nil) }
        let threeBroken = AgentReach(
            links: ["claude", "codex", "kiro", "cursor"]
                .map {
                    AgentReach.Link(target: target($0), state: $0 == "claude" ? .linked : .missing)
                })
        let crowded = AgentBadges.visible(threeBroken)
        #expect(crowded.shown.map(\.target.entry) == ["codex", "kiro"] && crowded.hidden == 2, "more broken than fit")
        let few = AgentBadges.visible(DesignFixtures.agentIndex(DesignFixtures.api).reach(of: DesignFixtures.pdf))
        #expect(few.shown.map(\.target.entry) == ["claude", "cursor"] && few.hidden == 0)
    }

    @Test func theHintNamesWhatFixesTheWorstState() {
        let hint = { (entry: SkillEntry, index: AgentIndex) in AgentCopy.hint(index.reach(of: entry)) }
        #expect(hint(DesignFixtures.agentsHandyNotes, Self.agents) == nil)
        #expect(hint(DesignFixtures.agentsReviewNotes, Self.agents)?.text == "Repair fixes missing and wrong links.")
        #expect(hint(DesignFixtures.agentsReviewNotes, Self.agents)?.seeHealth == true)
        #expect(hint(DesignFixtures.agentsReleaseChecklist, Self.agents)?.text.hasPrefix("A file or folder") == true)
        #expect(
            hint(DesignFixtures.agentsNotes, Self.agents)?.text.hasPrefix("The skill’s link into .agents/skills")
                == true)
        #expect(hint(DesignFixtures.agentsJiraSyntax, Self.agents)?.seeHealth == false)
        let target = AgentTarget(entry: "claude", directory: ".claude/skills")
        let storeBlocked = AgentReach(links: [AgentReach.Link(target: target, state: .storeBlocked)])
        // Repair (`doctor --fix`) never touches a foreign path, so the hint does not promise it fixes this.
        #expect(
            AgentCopy.hint(storeBlocked)?.text
                == "A file or folder skillcask did not create holds this name in .agents/skills, so no agent sees it. "
                + "Move it away, then Repair.")
        #expect(AgentCopy.summary(storeBlocked) == "Available to no agent; store blocked")
        let failed = DesignFixtures.agentIndex(DesignFixtures.agents, check: .failed)
        #expect(
            hint(DesignFixtures.agentsHandyNotes, failed)?.text
                == "The links could not be checked: the last check failed.")
        #expect(hint(DesignFixtures.agentsHandyNotes, failed)?.seeHealth == true)
    }

    @Test func theDetailListsEveryAgentWithItsLinkState() throws {
        let content = OverviewContent(
            entry: DesignFixtures.agentsReviewNotes, detail: nil, snapshot: DesignFixtures.agents, scope: Boot.apiScope,
            isOffline: false, agents: Self.agents.reach(of: DesignFixtures.agentsReviewNotes))
        let row = try #require(content.place.first { $0.label == DetailOverviewCopy.availableTo })
        guard case .agents(let reach) = row.value else {
            Issue.record("Available to is not the agent lines")
            return
        }
        #expect(
            reach.links.map { AgentCopy.state($0.state, readsStore: $0.target.directory == nil) } == [
                "linked", "installed", "link missing", "linked",
            ])
        let dependency = OverviewContent(
            entry: DesignFixtures.safeRefactor, detail: nil, snapshot: DesignFixtures.api, scope: Boot.apiScope,
            isOffline: false,
            agents: DesignFixtures.agentReach(
                of: DesignFixtures.safeRefactor, in: DesignFixtures.api, scope: Boot.apiScope))
        #expect(dependency.place.contains { $0.label == DetailOverviewCopy.availableTo }, "a dependency is linked too")
        let notManaged = OverviewContent(
            entry: DesignFixtures.standupSummary, detail: nil, snapshot: DesignFixtures.personal, scope: .personal,
            isOffline: false,
            agents: DesignFixtures.agentReach(
                of: DesignFixtures.standupSummary, in: DesignFixtures.personal, scope: .personal))
        #expect(!notManaged.place.contains { $0.label == DetailOverviewCopy.availableTo }, "no claim, no row")
        #expect(AgentCopy.state(.blocked) == "blocked" && AgentCopy.state(.storeLinkBroken) == "store link broken")
    }

    @Test func theAgentsCardCountsBrokenLinksPerOwnDirectoryAndTheStoreOnce() {
        #expect(
            AgentsCard.targets(Self.agents).map(\.directory) == [
                ".claude/skills", ".kiro/skills", ".agents/skills", "tools/skills",
            ])
        // notes' broken store link is named once, under "Not linked", not as a wrong link per agent.
        #expect(
            AgentsCard.footnote(DesignFixtures.agents, agents: Self.agents)
                == "5 skills are linked into all 4. Not linked: jira-syntax, notes. One Claude Code link is wrong — see "
                + "Health. One Kiro link is missing — see Health. One ./tools/skills link is broken — see Health.")
        #expect(OverviewCopy.brokenLinks([.missing, .wrong], agent: "Kiro") == "2 Kiro links are broken — see Health.")
    }

    @Test func afterAFailedDoctorTheAgentsCardStillNamesWhatHealthLists() {
        // The rows and the detail claim no link from the kept document, but the card counts its problems, as Health
        // lists them: a known broken link is no healthy claim.
        let failed = DesignFixtures.agentIndex(DesignFixtures.agents, check: .failed)
        #expect(failed.reach(of: DesignFixtures.agentsReviewNotes).links.allSatisfy { $0.state == .unknown })
        #expect(
            AgentsCard.footnote(DesignFixtures.agents, agents: failed)
                == AgentsCard.footnote(DesignFixtures.agents, agents: Self.agents))
    }

    @Test func theAgentsCardShowsHomePathsInTheGlobalScope() {
        let personal = DesignFixtures.agentIndex(DesignFixtures.personal, isGlobal: true)
        #expect(AgentsCard.targets(personal).map(\.directory) == ["~/.claude/skills", "~/.agents/skills"])
    }
}
