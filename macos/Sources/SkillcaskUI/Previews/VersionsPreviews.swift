import SkillcaskCore
import SkillcaskDomain
import SwiftUI

extension PreviewRegistry {
    /// The detail column (header and Versions tab) at 720 × 900, one state per Versions and Versions-States
    /// panel: `cooldown` (jira-communication, the Versions board), `upToDate` (commit-message), `withinRange` (pdf),
    /// `majorOutside` (legacy-lint), `tagMoved` (caveman, managed, after the tag moved), `expanded` (the cooldown
    /// with "All known versions" open over the package's fixture `info`), and that list while `info <package>`
    /// runs (`loading`: spinner and Cancel) or after it failed (`failure`: the error strip and Retry). Composed from `DetailHeader` and
    /// `VersionsTab` over fixture data, as `SkillDetailView` composes them, so no store task runs the network
    /// `info` during the render; the allowed range comes from the package fixtures' `why` lines.
    static let versions: [Entry] = [
        entry("cooldown") {
            VersionsSample(entry: DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo)
        },
        entry("upToDate") {
            VersionsSample(entry: DesignFixtures.commitMessage, info: DesignFixtures.commitMessageInfo, loaded: true)
        },
        entry("withinRange") { VersionsSample(entry: DesignFixtures.pdf, info: DesignFixtures.pdfInfo, loaded: true) },
        entry("majorOutside") { VersionsSample(entry: DesignFixtures.legacyLint, info: DesignFixtures.legacyLintInfo) },
        // The cooldown from a note-only `outdated` (the real 0.9.4 shape): eligible date from the note, release
        // date unknown.
        entry("cooldownNoteOnly") {
            VersionsSample(
                entry: DesignFixtures.entry("jira-communication", in: DesignFixtures.apiNoteOnly),
                info: DesignFixtures.jiraPackageInfo, snapshot: DesignFixtures.apiNoteOnly)
        },
        entry("tagMoved") {
            VersionsSample(entry: DesignFixtures.managedCaveman, info: nil, snapshot: DesignFixtures.apiTagMoved)
        },
        entry("expanded") {
            VersionsSample(
                entry: DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo, loaded: true,
                expanded: true)
        },
        entry("loading") {
            VersionsSample(
                entry: DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo, expanded: true,
                isLoading: true)
        },
        entry("failure") {
            VersionsSample(
                entry: DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo, expanded: true,
                loadError: .failed(code: .network, message: "packagist.org did not answer.", hint: nil, stderr: ""))
        },
    ]

    private static func entry(_ state: String, _ make: @escaping @MainActor @Sendable () -> VersionsSample) -> Entry {
        Entry(id: "P3-7", state: state, size: CGSize(width: 720, height: 900)) { AnyView(make()) }
    }
}

/// One detail column over fixture data: the header with the Versions tab selected and the tab's body. `loaded`
/// stands for a session cache that already holds the package's `info` (the list's count and "skipped").
private struct VersionsSample: View {
    let entry: SkillEntry
    let info: InfoDocument?
    var snapshot = DesignFixtures.api
    var loaded = false
    var expanded = false
    var isLoading = false
    var loadError: CLIError?
    @State private var tab = DetailTab.versions

    var body: some View {
        VStack(spacing: 0) {
            DetailHeader(
                entry: entry, selectedTab: $tab, requiredBy: snapshot.requirerSkills(of: entry), allowedRange: range)
            VersionsTab(
                content: VersionsContent(
                    model: model, versions: versions, agents: agents, checkedAt: snapshot.checkedAt, now: .now),
                package: entry.package ?? entry.id, versions: versions, isLoading: isLoading, loadError: loadError,
                initiallyExpanded: expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surfaceWindow)
    }

    private var range: String? {
        info.flatMap { DetailOverviewCopy.allowedRange(why: $0.why) }
    }

    private var model: VersionsModel {
        VersionsModel(
            entry: entry, policy: snapshot.policy, allowedRange: range,
            released: VersionsModel.released(in: loaded ? info : nil))
    }

    private var versions: [String]? {
        loaded ? info?.versions : nil
    }

    private var agents: [String] {
        snapshot.targets?.entries.map(ShellCopy.agentName) ?? []
    }
}
