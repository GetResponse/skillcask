import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The S3 header rules (`DetailActions.resolve`) over the design fixtures, the header's copy pinned to the Main
/// and Detail-States boards, and the tab titles in board order.
@Suite struct DetailHeaderTests {
    @Test func aMovedTagOffersReviewChangesNeverUpdate() {
        let actions = DetailActions.resolve(DesignFixtures.managedCaveman, offline: false)
        #expect(DetailActions.isTagMoved(DesignFixtures.managedCaveman))
        #expect(actions.primary == .reviewChanges)
        #expect(!actions.showsStrip)
        #expect(DetailActions.resolve(DesignFixtures.pdf, offline: false).primary == .update(to: "1.4.0"))
        #expect(!DetailActions.isTagMoved(DesignFixtures.pdf))
    }

    @Test func pdfOffersTheUpdateWithStripRemoveAndPill() {
        let actions = DetailActions.resolve(DesignFixtures.pdf, offline: false)
        #expect(actions.primary == .update(to: "1.4.0"))
        #expect(actions.showsRemove)
        #expect(actions.showsStrip)
        #expect(actions.showsSourcePill)
        #expect(!actions.showsPath)
        #expect(!actions.showsEditNote)
        #expect(DetailActions.updateTarget(of: DesignFixtures.pdf) == "1.4.0")
        #expect(DetailActions.packageText(of: DesignFixtures.pdf) == "anthropics/skills")
    }

    @Test func projectSkillShowsItsPathAndNoControls() {
        let actions = DetailActions.resolve(DesignFixtures.myNotes, offline: false)
        #expect(actions.primary == nil)
        #expect(!actions.showsRemove)
        #expect(!actions.showsStrip)
        #expect(!actions.showsSourcePill)
        #expect(actions.showsPath && DesignFixtures.myNotes.path == ".skills/my-notes")
        #expect(actions.showsEditNote)
        #expect(DetailActions.packageText(of: DesignFixtures.myNotes) == nil)
    }

    @Test func localSkillShowsItsPathAndNoControls() {
        let actions = DetailActions.resolve(DesignFixtures.deployChecklist, offline: false)
        #expect(DesignFixtures.deployChecklist.kind == .handWritten)
        #expect(actions.primary == nil)
        #expect(!actions.showsRemove && !actions.showsStrip && !actions.showsSourcePill)
        #expect(actions.showsPath && DesignFixtures.deployChecklist.path == ".claude/skills/deploy-checklist")
        #expect(!actions.showsEditNote)
    }

    @Test func packageOnlyRowBehavesLikeAPackage() {
        let gone = SkillEntry(
            id: "acme/gone", name: "acme/gone", kind: .packageOnly("acme/gone"), source: "packagist", version: nil,
            state: SkillState(cliState: "not in skills.lock"), health: .needsSync(reason: "not in skills.lock"),
            update: nil, findings: [], path: nil, description: nil)
        let actions = DetailActions.resolve(gone, offline: false)
        #expect(actions.primary == .updatesUnknown)
        #expect(actions.showsRemove && actions.showsSourcePill)
        #expect(!actions.showsStrip && !actions.showsPath && !actions.showsEditNote)
        #expect(DetailActions.packageText(of: gone) == "acme/gone")
    }

    @Test func dependencyNamesTheRequiringSkills() {
        #expect(DesignFixtures.api.requirerSkills(of: DesignFixtures.safeRefactor) == ["caveman"])
        #expect(DesignFixtures.api.requirerSkills(of: DesignFixtures.pdf) == [])
        #expect(DesignFixtures.api.requirerSkills(of: DesignFixtures.myNotes) == [])
    }

    @Test func dependencyHidesRemove() {
        let actions = DetailActions.resolve(DesignFixtures.safeRefactor, offline: false)
        #expect(actions.primary == .upToDate)
        #expect(!actions.showsRemove)
        #expect(!actions.showsStrip)
        #expect(actions.showsSourcePill)
    }

    @Test func notManagedAdoptsAndShowsItsAdoptSpec() {
        let known = DetailActions.resolve(DesignFixtures.caveman, offline: false)
        #expect(known.primary == .adopt)
        #expect(known.showsRemove)
        #expect(!known.showsStrip)
        #expect(known.showsSourcePill)
        #expect(DetailActions.packageText(of: DesignFixtures.caveman) == "juliusbrussee/caveman")

        let unknown = DetailActions.resolve(DesignFixtures.standupSummary, offline: false)
        #expect(unknown.primary == .adopt)
        #expect(unknown.showsRemove)
        #expect(!unknown.showsSourcePill)
        #expect(DetailActions.packageText(of: DesignFixtures.standupSummary) == nil)
    }

    @Test func currentAndAbandonedPackagesReadUpToDate() {
        let current = DetailActions.resolve(DesignFixtures.commitMessage, offline: false)
        #expect(current.primary == .upToDate)
        #expect(current.showsRemove && current.showsSourcePill && !current.showsStrip)
        let abandoned = DetailActions.resolve(DesignFixtures.legacyLint, offline: false)
        #expect(abandoned.primary == .upToDate)
        #expect(abandoned.showsRemove && abandoned.showsSourcePill && !abandoned.showsStrip)
    }

    @Test func offlineHidesTheStripAndReadsUpdatesUnknown() {
        let offlinePdf = DesignFixtures.entry("pdf", in: DesignFixtures.apiOffline)
        let actions = DetailActions.resolve(offlinePdf, offline: true)
        #expect(actions.primary == .updatesUnknown)
        #expect(!actions.showsStrip)
        #expect(actions.showsRemove && actions.showsSourcePill)
        // Even a row that still carries an update hides the strip and the button once the app is offline.
        let stale = DetailActions.resolve(DesignFixtures.pdf, offline: true)
        #expect(stale.primary == .updatesUnknown && !stale.showsStrip)
        // Online with no `outdated` answer at all the slot also reads "Updates unknown".
        let unchecked = DetailActions.resolve(DesignFixtures.commitMessageOffline, offline: false)
        #expect(unchecked.primary == .updatesUnknown)
    }

    @Test func tabsKeepTheBoardOrderAndTitles() {
        #expect(DetailTab.allCases == [.overview, .contents, .security, .versions])
        #expect(DetailTab.allCases.map(DetailCopy.tab) == ["Overview", "Contents", "Security", "Versions"])
        #expect(DetailCopy.sections == "Detail sections")
        // Q9: the titles are the four plain words; no count is ever appended (the board's "Versions 1" badge).
        #expect(DetailTab.allCases.map(DetailCopy.tab).allSatisfy { !$0.contains(where: \.isNumber) })
    }

    @Test func copyMatchesTheBoards() throws {
        #expect(DetailCopy.update(to: "1.4.0") == "Update to 1.4.0…")
        #expect(DetailCopy.adopt == "Adopt…")
        #expect(DetailCopy.upToDate == "Up to date")
        #expect(DetailCopy.updatesUnknown == "Updates unknown")
        #expect(DetailCopy.editInRepository == "Edit it in the repository")
        #expect(DetailCopy.remove == "Remove…")
        #expect(DetailCopy.reviewChanges == "Review changes…")
        #expect(DetailCopy.updateAvailable == "Update available")
        #expect(DetailCopy.noPackageRecorded == "No package recorded")
        #expect(DetailCopy.available("1.4.0") == "1.4.0 is available")
        #expect(DetailCopy.insideRange(nil) == "inside your allowed range.")
        #expect(DetailCopy.insideRange("^1.2") == "inside your allowed range ^1.2.")
        let released = try Date("2026-10-24T12:00:00Z", strategy: .iso8601)
        let now = try Date("2026-10-27T12:00:00Z", strategy: .iso8601)
        #expect(DetailCopy.released(released, now: now, timeZone: .gmt) == "Released 24 Oct 2026, 3 days ago.")
        #expect(Formatters.daysAgo(released, now: released, timeZone: .gmt) == "today")
        #expect(Formatters.daysAgo(released, now: released.addingTimeInterval(86_400), timeZone: .gmt) == "1 day ago")
    }

    static func update(_ json: String) throws -> Update {
        Update(try JSONDecoder().decode(OutdatedDocument.Package.self, from: Data(json.utf8)))
    }

    /// The strip offers `within`; `latest`'s time must not stand next to it when the two differ (D67).
    @Test func theStripDatesWithinNotLatest() throws {
        let update = try Self.update(
            #"{"package":"acme/s","locked":"1.2.0","within":"1.4.0","latest":"2.0.0","note":null,"#
                + #""within-released":"2026-10-24T12:00:00Z","latest-released":"2026-11-02T12:00:00Z","#
                + #""released":"2026-11-02T12:00:00Z"}"#)
        let released = try #require(DetailHeader.targetReleased(update))
        let now = try Date("2026-10-27T12:00:00Z", strategy: .iso8601)
        #expect(DetailCopy.released(released, now: now, timeZone: .gmt) == "Released 24 Oct 2026, 3 days ago.")
    }

    /// pdf is a GitHub package (D67): nothing dates the offered 1.4.0, so the strip names no date.
    @Test func aGitHubTargetIsUndated() {
        #expect(DetailHeader.targetReleased(DesignFixtures.pdfUpdate) == nil)
    }

    @Test func withoutWithinReleasedTheStripDatesOnlyAWithinThatIsLatest() throws {
        let beyond = try Self.update(
            #"{"package":"acme/s","locked":"1.2.0","within":"1.4.0","latest":"2.0.0","note":null,"#
                + #""released":"2026-11-02T12:00:00Z"}"#)
        #expect(DetailHeader.targetReleased(beyond) == nil)
        let same = try Self.update(
            #"{"package":"acme/s","locked":"1.2.0","within":"1.4.0","latest":"1.4.0","note":null,"#
                + #""released":"2026-10-24T12:00:00Z"}"#)
        #expect(DetailHeader.targetReleased(same) == (try Date("2026-10-24T12:00:00Z", strategy: .iso8601)))
        let old = try Self.update(#"{"package":"acme/s","locked":"1.2.0","within":"1.4.0","latest":"1.4.0"}"#)
        #expect(DetailHeader.targetReleased(old) == nil)
    }
}
