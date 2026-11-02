import Foundation
import SkillcaskCore
import SkillcaskDomain
import SwiftUI
import Testing

@testable import SkillcaskUI

/// The Scope Overview (S1): which board state shows, the strip sentence of each, the doctor, policy and source
/// humanisation, the card title → filter mapping, the healthy collapse rule and the loading toolbar rule.
@MainActor @Suite struct OverviewTests {
    // MARK: - States and strip

    private func state(
        _ snapshot: ScopeSnapshot?, presentation: Presentation = .ready, isSetUp: Bool = true,
        isPersonal: Bool = false, hasProjects: Bool = true
    ) -> OverviewState {
        OverviewState.resolve(
            snapshot: snapshot, presentation: presentation, isSetUp: isSetUp, isPersonal: isPersonal,
            hasProjects: hasProjects)
    }

    @Test func stateFollowsTheBoards() {
        #expect(state(DesignFixtures.api) == .ready(DesignFixtures.api))
        #expect(state(nil, presentation: .loading) == .loading)
        #expect(state(nil, presentation: .noManifest) == .notSetUp)
        #expect(state(DesignFixtures.api, isSetUp: false) == .notSetUp)
        #expect(
            state(DesignFixtures.personal, isPersonal: true, hasProjects: false) == .noProjects(DesignFixtures.personal)
        )
        #expect(state(DesignFixtures.personal, isPersonal: true, hasProjects: true) == .ready(DesignFixtures.personal))
    }

    @Test func stripSentencePerState() {
        let api = DesignFixtures.api
        let attention = state(api).strip(now: api.checkedAt.addingTimeInterval(4 * 60))
        #expect(attention.sentence == "14 skills · 3 need sync · 5 need a decision · 2 updates · Checked 4 min ago")

        let website = DesignFixtures.website
        let healthy = state(website).strip(now: website.checkedAt.addingTimeInterval(2 * 60))
        #expect(healthy.sentence == "3 skills · All match the lock · Checked 2 min ago")
        #expect(healthy.segments.last?.dot == .severity(.ok))

        let personal = DesignFixtures.personal
        let noProjects = state(personal, isPersonal: true, hasProjects: false).strip(now: personal.checkedAt)
        #expect(noProjects.sentence.hasPrefix("23 skills · 12 not managed"))
        #expect(noProjects.sentence.hasSuffix("Checked just now"))

        #expect(attention.showsCheckNow)
        #expect(healthy.showsCheckNow)
        #expect(!noProjects.showsCheckNow)

        #expect(state(nil, presentation: .loading).strip().sentence == "Checking this project…")
        #expect(state(nil, presentation: .loading).strip().isLoading)
        #expect(state(nil, isSetUp: false).strip().sentence == "Not set up")
        #expect(state(nil, isSetUp: false).strip().segments.first?.dot == .notSetUp)
    }

    @Test func failedLoadHasItsOwnStateWithoutTheLoadingStrip() {
        let error = CLIError.failed(code: .problem, message: "skills.lock is not valid TOML", hint: nil, stderr: "")
        let failed = state(nil, presentation: .error(error))
        #expect(failed == .failed(error))
        #expect(!failed.strip().isLoading)
        #expect(failed.strip().sentence.isEmpty)
        #expect(!failed.strip().showsCheckNow)
        #expect(state(nil, presentation: .loading).strip().isLoading)
    }

    // MARK: - Doctor

    @Test func doctorLinesAreTypedAndHumanised() {
        let table: [(line: String, sentence: String, hint: String?)] = [
            (".cursor/skills/pdf: link wrong", ".cursor/skills/pdf link points elsewhere", "Repair fixes this"),
            (
                ".skillcask/skills/jira-syntax: not installed (netresearch/agent-jira-skill); run `skillcask install`",
                "jira-syntax is in skills.lock but not installed", "Sync fixes this"
            ),
            (
                ".skillcask/skills/x: modified (acme/x); run `skillcask install` to restore",
                "x differs from the version in the lock", "Sync fixes this"
            ),
            (".gitignore: stale managed block", ".gitignore managed block is out of date", "Repair fixes this"),
            (".claude/skills/a: link missing", ".claude/skills/a link is missing", "Repair fixes this"),
            ("something new", "something new", nil),
        ]
        for row in table {
            let line = OverviewCopy.problem(DoctorItem(line: row.line))
            #expect(line.sentence == row.sentence)
            #expect(line.hint == row.hint)
            #expect(!line.sentence.contains("skillcask install"))
        }
        #expect(
            DoctorItem(line: ".skillcask/skills/jira-syntax: not installed (netresearch/agent-jira-skill); run x")
                == .notInstalled(skill: "jira-syntax", package: "netresearch/agent-jira-skill"))
        #expect(DoctorItem(line: "links: 26 ok") == .linksOk(26))
        #expect(DoctorItem(line: "installed: 3 skill(s) match skills.lock") == .installedMatch(3))
        #expect(OverviewCopy.passed(.gitIndexClean) == "Git index does not track installed skills")
        #expect(OverviewCopy.passed(.installedMatch(3)) == "Every locked skill is installed with the locked content")
        #expect(
            OverviewCopy.fixed(DoctorItem(line: ".cursor/skills/pdf: link wrong")).sentence
                == "Relinked .cursor/skills/pdf to the installed copy.")
    }

    @Test func repairIsEnabledOnlyWhenItHasSomethingToFix() throws {
        let api = try #require(DesignFixtures.api.doctor)
        #expect(api.canRepair)
        let repaired = try #require(DesignFixtures.apiRepaired.doctor)
        #expect(!repaired.canRepair)
        #expect(
            AgentsCard.footnote(DesignFixtures.api, agents: DesignFixtures.agentIndex(DesignFixtures.api))
                == "12 skills are linked into both. Not linked: jira-syntax, sql-review. One Claude Code link is wrong — see "
                + "Health.")
        #expect(AgentsCard.unlinked(DesignFixtures.api) == ["jira-syntax", "sql-review"])
        #expect(AgentsCard.unlinked(DesignFixtures.website).isEmpty, "a healthy project links every skill")
        #expect(OverviewCopy.linked(skills: 0, agents: 2) == "No skills linked yet.", "an empty project")
        #expect(OverviewCopy.linked(skills: 1, agents: 2) == "1 skill is linked into both.")
    }

    // MARK: - Policy and sources

    @Test func policyKeysValuesAndOriginsReadAsTheBoard() {
        let api = DesignFixtures.api.policy
        let names = api.map { OverviewCopy.policyName($0.kind) }
        #expect(names == ["Minimum release age", "Allowed sources", "Ranges allowed"])
        #expect(
            ["zeta", "allow-ranges", "alpha", "allow-sources", "min-release-age"]
                .sorted(by: ScopeSnapshot.PolicyRow.Kind.precedes)
                == ["min-release-age", "allow-sources", "allow-ranges", "alpha", "zeta"])
        let age = api.first { $0.kind == .minReleaseAge }
        #expect(age.map(OverviewCopy.policyValue) == "72 h")
        #expect(age.map { OverviewCopy.enforcedOrigin($0.origin) } == "config.toml · enforced")
        #expect(api.first { $0.kind == .allowRanges }.map(OverviewCopy.policyValue) == "Yes")
        let any = DesignFixtures.website.policy.first { $0.kind == .allowSources }
        #expect(any.map(OverviewCopy.policyValue) == "any")
        #expect(OverviewCopy.minimumAge(api) == "72 h")
        #expect(OverviewCopy.minimumAge(DesignFixtures.website.policy) == nil)
    }

    @Test func addressesWrapOnlyAfterASlashOrADot() {
        #expect(OverviewCopy.addressRuns("packagist.org") == ["packagist.", "org"])
        #expect(
            OverviewCopy.addressRuns("skills.acme.example/packages.json")
                == ["skills.", "acme.", "example/", "packages.", "json"])
        #expect(OverviewCopy.addressRuns("a/b/") == ["a/", "b/"])
        #expect(OverviewCopy.addressRuns("").isEmpty)
    }

    @Test func sourcesReadAsTheBoard() {
        let rows = DesignFixtures.api.repositories.map {
            [OverviewCopy.sourceType($0), OverviewCopy.sourceAddress($0)]
        }
        #expect(
            rows == [
                ["Packagist", "packagist.org"], ["GitHub", "github.com"],
                ["Custom repository", "skills.acme.example/packages.json"],
            ])
        #expect(
            SourcesCard.footnote(DesignFixtures.api)
                == "GitHub is blocked by Allowed sources, set in config.toml by your organisation. Skills from it "
                + "stay installed but cannot be added or updated here.")
        #expect(SourcesCard.footnote(DesignFixtures.website) == nil)
    }

    // MARK: - Cards

    @Test func findingsReadAsTheBoard() {
        let lines = SecurityCard.findings(DesignFixtures.api).map(\.sentence)
        #expect(
            lines == [
                "my-notes asks an agent to download and run a script (line 17)",
                "my-notes contains an invisible character (line 3)",
            ])
    }

    @Test func updateRowsAreNamedBySkillInListOrder() {
        let rows = UpdatesCard.rows(DesignFixtures.api)
        #expect(rows.map(\.name) == ["pdf", "review-pr"])
        #expect(rows.map(\.package) == ["anthropics/skills", "acme/review-pr"])
        #expect(rows.first.map { Labels.versionTransition(from: $0.from, to: $0.to) } == "1.2.0 → 1.4.0")
        #expect(UpdatesCard.rows(DesignFixtures.website).isEmpty)
    }

    @Test func cardTitleTapShowsTheFilterAndClearsTheSelection() {
        let store = ScopeStore(
            scope: Boot.apiScope, client: FakeCLIClient(), capabilities: Capabilities(version: Capabilities.minimum))
        store.preload(snapshot: DesignFixtures.api, selection: "pdf")
        ScopeOverviewView.show(ScopeOverviewView.filter(for: .updates), in: store)
        #expect(store.selection == nil)
        #expect(store.filter == .updates)
    }

    @Test func cardTitlesOpenTheFilteredList() {
        #expect(ScopeOverviewView.filter(for: .health) == .needsAttention)
        #expect(ScopeOverviewView.filter(for: .security) == .needsAttention)
        #expect(ScopeOverviewView.filter(for: .updates) == .updates)
    }

    @Test func healthyProjectCollapsesEveryCard() {
        let website = DesignFixtures.website
        #expect(HealthCard.isCollapsed(website))
        #expect(UpdatesCard.isCollapsed(website))
        #expect(SecurityCard.isCollapsed(website))
        #expect(ScopeOverviewView.isQuiet(website))
        // Only an error card takes a coloured border; the healthy cards keep the separator.
        #expect(HealthCard.severity(website) == .ok)
        #expect(CardContainer<EmptyView, EmptyView>.borderColor(for: .ok) == .separator)

        let api = DesignFixtures.api
        #expect(!HealthCard.isCollapsed(api))
        #expect(!UpdatesCard.isCollapsed(api))
        #expect(!SecurityCard.isCollapsed(api))
        #expect(!ScopeOverviewView.isQuiet(api))
        #expect(HealthCard.severity(api) == .error)
        #expect(OverviewCopy.securityStatus(changed: 0, findings: 0) == "no findings")
        #expect(OverviewCopy.updatesStatus(available: 0, checked: true) == "none")
    }

    @Test func cooldownLineNamesTheDateAndTheMinimumAge() throws {
        let api = DesignFixtures.api
        let cooldown = try #require(UpdatesCard.cooldowns(api).first)
        let line = OverviewCopy.cooldown(
            ["jira-syntax", "jira-communication"], update: cooldown, minimumAge: OverviewCopy.minimumAge(api.policy))
        #expect(line.hasPrefix("jira-syntax, jira-communication: 4.3.0 becomes available on "))
        #expect(line.hasSuffix(" (minimum release age 72 h)."))
    }

    // MARK: - Toolbar

    @Test func loadingDisablesTheToolbar() {
        #expect(!ToolbarRules.isLoaded(nil))
        #expect(ToolbarRules.isLoaded(DesignFixtures.api))
    }
}
