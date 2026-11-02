import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The S3 Overview tab over the design fixtures: tabs per kind, the `why` rewording, the requiring skills by
/// name, the Detail-States strips, the offline state keeping the status-known rows, and Esc clearing selection.
@Suite @MainActor struct SkillDetailTests {
    // MARK: - Tabs

    @Test func versionsIsHiddenForProjectLocalAndNotManagedSkills() {
        let all: [DetailTab] = [.overview, .contents, .security, .versions]
        let three: [DetailTab] = [.overview, .contents, .security]
        #expect(DetailTabs.tabs(for: DesignFixtures.pdf) == all)
        #expect(DetailTabs.tabs(for: DesignFixtures.safeRefactor) == all)
        #expect(DetailTabs.tabs(for: DesignFixtures.myNotes) == three)
        #expect(DetailTabs.tabs(for: DesignFixtures.deployChecklist) == three)
        #expect(DetailTabs.tabs(for: DesignFixtures.caveman) == three)
        #expect(DetailTabs.tabs(for: DesignFixtures.standupSummary) == three)
    }

    @Test func aHiddenTabFallsBackToOverview() {
        #expect(DetailTabs.resolve(.versions, in: DetailTabs.tabs(for: DesignFixtures.myNotes)) == .overview)
        #expect(DetailTabs.resolve(.security, in: DetailTabs.tabs(for: DesignFixtures.myNotes)) == .security)
        #expect(DetailTabs.resolve(.versions, in: DetailTabs.tabs(for: DesignFixtures.pdf)) == .versions)
    }

    // MARK: - why

    @Test func whyLinesAreRewordedWithSkillNames() {
        let names = { (package: String) in DesignFixtures.api.skillNames(ofPackage: package) }
        #expect(
            DetailOverviewCopy.requiredBy(why: DesignFixtures.safeRefactorInfo.why, skillNames: names)
                == "caveman (4.0.1)")
        // The package's own manifest line is no requirer: the row reads "Nothing. Added directly…".
        #expect(DetailOverviewCopy.requiredBy(why: DesignFixtures.pdfInfo.why, skillNames: names) == nil)
        // A requiring package without a skill in the scope is named by itself.
        #expect(
            DetailOverviewCopy.requiredBy(why: ["a/b: required by acme/other (1.0.0)"], skillNames: { _ in [] })
                == "acme/other (1.0.0)")
        // Any other shape keeps the CLI's words, without the package prefix.
        #expect(DetailOverviewCopy.requiredBy(why: ["a/b: pinned by policy"], skillNames: names) == "pinned by policy")
        #expect(DetailOverviewCopy.allowedRange(why: DesignFixtures.legacyLintInfo.why) == "^2.0")
        #expect(DetailOverviewCopy.allowedRange(why: DesignFixtures.safeRefactorInfo.why) == nil)
    }

    @Test func requiredByNamesTheRequiringSkill() {
        let content = overview(DesignFixtures.safeRefactor, info: DesignFixtures.safeRefactorInfo)
        #expect(content.banners == [.dependency(skill: "safe-refactor", requirers: ["caveman"])])
        #expect(value(DetailOverviewCopy.requiredBy, in: content.facts) == .text("caveman (4.0.1)", mono: nil))
        #expect(
            DetailOverviewCopy.dependency("safe-refactor", requiredBy: ["caveman"])
                == "safe-refactor is here because caveman requires it. Remove caveman to drop it.")
        #expect(DesignFixtures.api.skillNames(ofPackage: "anthropics/skills") == ["pdf", "test-writer"])
    }

    // MARK: - States

    @Test func mainBoardPdfShowsThePackageAndPlaceCards() {
        let content = overview(DesignFixtures.pdf, info: DesignFixtures.pdfInfo)
        #expect(content.banners.isEmpty)
        #expect(
            content.facts.map(\.label) == [
                DetailOverviewCopy.skillsInPackage, DetailOverviewCopy.license, DetailOverviewCopy.requiredBy,
                DetailOverviewCopy.requires, DetailOverviewCopy.repository,
            ])
        #expect(value(DetailOverviewCopy.requiredBy, in: content.facts) == .quiet(DetailOverviewCopy.addedDirectly))
        #expect(
            DetailOverviewCopy.repositoryText("https://github.com/anthropics/skills") == "github.com/anthropics/skills")
        guard case .folder(let path, _) = value(DetailOverviewCopy.location, in: content.place) else {
            Issue.record("pdf has no Location row")
            return
        }
        #expect(path == "~/work/api/.skillcask/skills/pdf")
        guard case .agents(let reach) = value(DetailOverviewCopy.availableTo, in: content.place) else {
            Issue.record("pdf has no Available to row")
            return
        }
        // Claude Code's link is wrong (doctor.api); Cursor reads the store.
        #expect(reach.links.map(\.target.entry) == ["claude", "cursor"])
        #expect(reach.links.map(\.state) == [.wrong, .linked])
    }

    @Test func installedSiblingsOfThePackageAreMarkedInstalled() {
        let pdf = overview(DesignFixtures.pdf, info: DesignFixtures.pdfInfo)
        guard case .skills(let installed, let others) = value(DetailOverviewCopy.skillsInPackage, in: pdf.facts) else {
            Issue.record("pdf has no skills row")
            return
        }
        #expect(installed == ["pdf"], "no other skill of anthropics/skills is installed in api")
        #expect(others == DesignFixtures.pdfInfo.skills.map(\.name).filter { $0 != "pdf" }, "unchanged otherwise")
        let after = AddSkillSamples.afterAdd
        let syntax = DesignFixtures.entry("jira-syntax", in: after)
        let siblings = OverviewContent.installedSiblings(["jira-communication", "other"], of: syntax, in: after)
        #expect(siblings == ["jira-communication"])
        #expect(
            OverviewContent.installedSiblings(
                ["jira-syntax"], of: DesignFixtures.jiraCommunication, in: DesignFixtures.api) == [],
            "jira-syntax is not installed in the api fixture")
    }

    @Test func projectSkillShowsItsKindAndNoPackageCard() {
        let content = overview(DesignFixtures.myNotes, info: DesignFixtures.myNotesInfo)
        #expect(content.banners.isEmpty)
        #expect(content.facts.isEmpty)
        #expect(content.state == .project)
        #expect(
            content.place.map(\.label) == [
                DetailOverviewCopy.kind, DetailOverviewCopy.availableTo, DetailOverviewCopy.location,
            ])
    }

    @Test func eachStateShowsTheBoardsRows() {
        #expect(
            OverviewContent.fields(for: .package) == [
                .skills, .license, .requiredBy, .requires, .repository, .newest, .availableTo, .location, .security,
            ])
        #expect(OverviewContent.fields(for: .project) == [.kind, .availableTo, .location])
        #expect(OverviewContent.fields(for: .local) == [.kind, .availableTo, .location])
        #expect(OverviewContent.fields(for: .dependency) == [.requiredBy, .requires, .availableTo])
        #expect(OverviewContent.fields(for: .notManaged) == [.foundIn, .security])
        #expect(OverviewContent.fields(for: .sourceUnknown) == [.foundIn, .security])
        #expect(OverviewContent.fields(for: .abandoned) == [.license, .newest])
        #expect(OverviewContent.fields(for: .offline) == [.availableTo, .plainLocation, .security])
    }

    /// Who requires it, what it requires, and which agents see it (a dependency is linked like any package).
    @Test func dependencyShowsWhoRequiresItWhatItRequiresAndItsAgents() {
        let content = overview(DesignFixtures.safeRefactor, info: DesignFixtures.safeRefactorInfo)
        #expect(content.state == .dependency)
        #expect(content.facts.map(\.label) == [DetailOverviewCopy.requiredBy, DetailOverviewCopy.requires])
        #expect(content.place.map(\.label) == [DetailOverviewCopy.availableTo])
    }

    // MARK: - Header state line

    @Test func headerStatesTheStateNotTheFindings() {
        #expect(DetailHeader.stateHealth(for: DesignFixtures.myNotes) == .projectSkill)
        #expect(DetailHeader.stateHealth(for: DesignFixtures.standupSummary) == .notManaged)
        #expect(DetailHeader.stateHealth(for: DesignFixtures.deployChecklist) == .changedOnDisk)
        #expect(DetailHeader.stateHealth(for: DesignFixtures.pdf) == .updateAvailable(from: "1.2.0", to: "1.4.0"))
        // The list row keeps the findings.
        #expect(DesignFixtures.myNotes.health == .findings(2))
    }

    @Test func notManagedStripsFollowTheAdoptSpec() {
        let known = overview(DesignFixtures.caveman, info: nil)
        #expect(known.banners == [.notManaged(spec: "github:juliusbrussee/caveman")])
        #expect(known.facts.isEmpty)
        #expect(known.place.map(\.label) == [DetailOverviewCopy.foundIn, DetailOverviewCopy.security])
        let unknown = overview(
            DesignFixtures.standupSummary, info: nil, snapshot: DesignFixtures.personal, scope: .personal)
        #expect(unknown.banners == [.sourceUnknown])
        #expect(unknown.state == .sourceUnknown)
    }

    @Test func abandonedNamesTheReplacementAndTheNewestOutsideTheRange() {
        let content = overview(DesignFixtures.legacyLint, info: DesignFixtures.legacyLintInfo)
        #expect(content.banners == [.abandoned(replacement: "acme/lint2")])
        #expect(content.facts.map(\.label) == [DetailOverviewCopy.license, DetailOverviewCopy.newest])
        #expect(content.place.isEmpty)
        #expect(
            value(DetailOverviewCopy.newest, in: content.facts)
                == .text("3.0.0 exists but needs a range change (allowed: ^2.0)", mono: "^2.0"))
    }

    @Test func offlineShowsTheStripAndKeepsStatusKnownRows() {
        let detail = SkillDetail(infoError: .failed(code: .network, message: "", hint: nil, stderr: ""))
        let offlineReach = DesignFixtures.agentReach(
            of: DesignFixtures.commitMessageOffline, in: DesignFixtures.apiOffline, scope: Boot.apiScope)
        let content = OverviewContent(
            entry: DesignFixtures.commitMessageOffline, detail: detail, snapshot: DesignFixtures.apiOffline,
            scope: Boot.apiScope, isOffline: false, agents: offlineReach)
        #expect(content.banners == [.offline])
        #expect(content.facts.isEmpty)
        #expect(
            content.place.map(\.label) == [
                DetailOverviewCopy.availableTo, DetailOverviewCopy.location, DetailOverviewCopy.security,
            ])
        #expect(
            value(DetailOverviewCopy.security, in: content.place)
                == .security(.ok, "No findings (audit runs locally)", link: false))
        // Offline the location is plain mono, without "Open folder" (Detail-States).
        #expect(
            value(DetailOverviewCopy.location, in: content.place)
                == .mono("~/work/api/.skillcask/skills/commit-message"))
        // The app offline with no detail yet reads the same; online without an answer shows no strip.
        let waiting = OverviewContent(
            entry: DesignFixtures.commitMessageOffline, detail: nil, snapshot: DesignFixtures.apiOffline,
            scope: Boot.apiScope, isOffline: true, agents: offlineReach)
        #expect(waiting.banners == [.offline])
        let online = OverviewContent(
            entry: DesignFixtures.commitMessageOffline, detail: nil, snapshot: DesignFixtures.apiOffline,
            scope: Boot.apiScope, isOffline: false, agents: offlineReach)
        #expect(online.banners.isEmpty)
    }

    @Test func footnoteAndStripQuoteTheBoards() {
        let now = Date()
        #expect(
            DetailOverviewCopy.lastChecked(now.addingTimeInterval(-4 * 60), now: now)
                == "Last checked 4 min ago from skills.lock. Numbers come from the command-line tool, never estimated.")
        #expect(DetailOverviewCopy.lastChecked(now, now: now).hasPrefix("Last checked just now from skills.lock."))
        #expect(DetailOverviewCopy.allowedRange(why: DesignFixtures.pdfInfo.why) == "^1.2")
    }

    // MARK: - Selection

    @Test func clearSelectionReturnsToTheScopeOverview() {
        let store = ScopeStore(
            scope: Boot.apiScope, client: FixtureCLIClient(), capabilities: Capabilities(version: Capabilities.minimum))
        store.preload(snapshot: DesignFixtures.api, selection: "pdf", detail: SkillDetail(info: DesignFixtures.pdfInfo))
        #expect(store.selectedEntry?.id == "pdf")
        store.clearSelection()
        #expect(store.selection == nil)
        #expect(store.selectedEntry == nil)
        #expect(store.detail == nil)
    }

    // MARK: - Helpers

    private func overview(
        _ entry: SkillEntry, info: InfoDocument?, snapshot: ScopeSnapshot = DesignFixtures.api,
        scope: Scope = Boot.apiScope
    ) -> OverviewContent {
        OverviewContent(
            entry: entry, detail: SkillDetail(info: info), snapshot: snapshot, scope: scope, isOffline: false,
            agents: DesignFixtures.agentReach(of: entry, in: snapshot, scope: scope))
    }

    private func value(_ label: String, in rows: [OverviewContent.Row]) -> OverviewContent.Value? {
        rows.first { $0.label == label }?.value
    }
}
