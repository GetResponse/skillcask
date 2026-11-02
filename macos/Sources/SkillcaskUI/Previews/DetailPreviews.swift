import SkillcaskCore
import SkillcaskDomain
import SwiftUI

extension PreviewRegistry {
    /// The detail column (header and Overview tab) at 720 × 800 for the Main board's pdf and every
    /// Detail-States state. Composed from `DetailHeader` and `OverviewTab` over fixture data, as `SkillDetailView`
    /// composes them, so no store task reloads the detail during the render (the offline state keeps no `info`).
    ///
    /// `cli` comes first: pdf as the 0.9.4 CLI's `status` reports it (`DesignFixtures.apiCLI`: no `source` or
    /// `description` key). `notManaged` (caveman in the api project) is a planned shape: 0.9.4 reports not managed
    /// skills in the personal scope only; `notManagedUnknown` is the reachable one.
    static let detail: [Entry] = [
        entry("cli") {
            DetailSample(
                entry: DesignFixtures.entry("pdf", in: DesignFixtures.apiCLI), info: DesignFixtures.pdfInfo,
                snapshot: DesignFixtures.apiCLI)
        },
        entry("update") { DetailSample(entry: DesignFixtures.pdf, info: DesignFixtures.pdfInfo) },
        entry("project") { DetailSample(entry: DesignFixtures.myNotes, info: DesignFixtures.myNotesInfo) },
        entry("dependency") { DetailSample(entry: DesignFixtures.safeRefactor, info: DesignFixtures.safeRefactorInfo) },
        entry("notManaged") { DetailSample(entry: DesignFixtures.caveman, info: nil) },
        entry("notManagedUnknown") {
            DetailSample(
                entry: DesignFixtures.standupSummary, info: nil, snapshot: DesignFixtures.personal, scope: .personal)
        },
        entry("abandoned") { DetailSample(entry: DesignFixtures.legacyLint, info: DesignFixtures.legacyLintInfo) },
        entry("agentsLinkMissing") {
            DetailSample(entry: DesignFixtures.agentsReviewNotes, info: nil, snapshot: DesignFixtures.agents)
        },
        entry("agentsBlocked") {
            DetailSample(entry: DesignFixtures.agentsReleaseChecklist, info: nil, snapshot: DesignFixtures.agents)
        },
        entry("agentsStoreLink") {
            DetailSample(entry: DesignFixtures.agentsNotes, info: nil, snapshot: DesignFixtures.agents)
        },
        entry("agentsNotInstalled") {
            DetailSample(entry: DesignFixtures.agentsJiraSyntax, info: nil, snapshot: DesignFixtures.agents)
        },
        entry("agentsUnchecked") {
            DetailSample(
                entry: DesignFixtures.agentsReviewNotes, info: nil, snapshot: DesignFixtures.agents, check: .failed)
        },
        entry("offline") {
            DetailSample(
                entry: DesignFixtures.commitMessageOffline, info: nil, snapshot: DesignFixtures.apiOffline,
                offline: true)
        },
    ]

    private static func entry(_ state: String, _ make: @escaping @MainActor @Sendable () -> DetailSample) -> Entry {
        Entry(id: "P3-3", state: state, size: CGSize(width: 720, height: 800)) { AnyView(make()) }
    }
}

/// One detail column over fixture data: the header with the Overview tab selected and the tab's body.
private struct DetailSample: View {
    let entry: SkillEntry
    let info: InfoDocument?
    var snapshot = DesignFixtures.api
    var scope = Boot.apiScope
    var offline = false
    var check: AgentIndex.LinkCheck?
    @State private var tab = DetailTab.overview

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                entry: entry, isOffline: offline, selectedTab: $tab, requiredBy: snapshot.requirerSkills(of: entry),
                allowedRange: info.flatMap { DetailOverviewCopy.allowedRange(why: $0.why) })
            OverviewTab(
                content: OverviewContent(
                    entry: entry, detail: detail, snapshot: snapshot, scope: scope, isOffline: offline,
                    agents: DesignFixtures.agentIndex(snapshot, isGlobal: scope.isPersonal, check: check)
                        .reach(of: entry)),
                checkedAt: snapshot.checkedAt)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surfaceWindow)
    }

    private var detail: SkillDetail {
        offline
            ? SkillDetail(
                infoError: .failed(code: .network, message: "github.com did not answer.", hint: nil, stderr: ""))
            : SkillDetail(info: info)
    }
}
