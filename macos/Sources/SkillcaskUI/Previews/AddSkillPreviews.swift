import Foundation
import SkillcaskCore
import SkillcaskDomain
import SwiftUI

extension PreviewRegistry {
    /// The Add Skill sheet (S8) at its board size over the api scope, in the states of the AddSkill and
    /// AddSkill-States boards. `preview` is the AddSkill board ("jira", consent card, the selected package's
    /// preview); `name-clash` is the 0.9.4 path (the CLI's error after Add); `capable-name-clash` and
    /// `capable-skills` run against a CLI with the planned `add --rename` and `add --skill` (not shipped at 0.9.4).
    /// `added` is the sheet after an add, still open: the added row selected and marked Installed, the footer saying
    /// what was added, Done in place of Cancel. `success` is the window after that sheet closed: the toast in the
    /// list column, the new skill selected.
    /// `rule-branch` and `rule-latest` show Flow-F2's Branch and Latest rules on the rule button. The source
    /// filter's states search My Skills for "pocock": `filter-source` narrows to skills.sh (GitHub dimmed at 0),
    /// `filter-empty` keeps a GitHub filter from an earlier query ("No results from GitHub", Show All), and
    /// `installs-column` is the unfiltered list whose long `github:` names truncate before the 4- and 5-digit counts.
    /// `preview-large` and `progress-large` draw the resizable sheet at 1280×860. `progress-waiting` and
    /// `progress-waiting-large` (at the 1600×1100 cap) are the run before the CLI's first line.
    static let addSkill: [Entry] = [
        sheet("preview", boardScope: true) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .undecided,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        sheet("idle") { $0.preload(query: "") },
        sheet("searching") { $0.preload(query: DesignFixtures.jiraQuery, results: .searching) },
        sheet("preview-loading", boardScope: true) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .enabled,
                selection: AddSkillSamples.jiraPackage)
        },
        sheet("progress", boardScope: true, previewState: .progress) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        sheet("added", previewState: .added, snapshot: AddSkillSamples.afterAdd) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        sheet("not-found") {
            $0.preload(
                query: DesignFixtures.notFoundQuery, selection: DesignFixtures.notFoundQuery,
                infoError: AddSkillSamples.notFound)
        },
        sheet("blocked") {
            $0.preload(
                query: DesignFixtures.blockedQuery, selection: DesignFixtures.blockedQuery,
                infoError: AddSkillSamples.blocked)
        },
        sheet("name-clash", previewState: .clashFailure) {
            $0.preload(
                query: AddSkillSamples.kolyaPackage, selection: AddSkillSamples.kolyaPackage,
                info: AddSkillSamples.kolyaInfo)
        },
        sheet("capable-name-clash", capable: true) {
            $0.preload(
                query: AddSkillSamples.kolyaPackage, selection: AddSkillSamples.kolyaPackage,
                info: AddSkillSamples.kolyaInfo)
        },
        sheet("capable-skills", capable: true, boardScope: true) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
            $0.excludedSkills = ["jira-communication"]
        },
        sheet("empty") {
            $0.preload(
                query: DesignFixtures.noResultsQuery, results: .loaded(DesignFixtures.noResults), skillsSh: .disabled)
        },
        sheet("network") {
            $0.preload(query: DesignFixtures.jiraQuery, results: .failed(AddSkillSamples.unreachable))
        },
        sheet("source") {
            $0.preload(query: DesignFixtures.sourceQuery, selection: DesignFixtures.sourceQuery)
        },
        // Flow-F2's Branch rule on a GitHub source (the popover is a window of its own; the button shows it).
        sheet("rule-branch") {
            $0.preload(
                query: AddSkillSamples.githubJira, selection: AddSkillSamples.githubJira, info: AddSkillSamples.jiraInfo
            )
            $0.rule = .branch("")
            $0.branch = "release-2024"
        },
        sheet("rule-latest", boardScope: true) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
            $0.rule = .latest
        },
        sheet("filter-source", personal: true) {
            $0.preload(
                query: DesignFixtures.pocockQuery, results: .loaded(DesignFixtures.pocockSearch), skillsSh: .enabled)
            $0.sourceFilter = "skills.sh"
        },
        sheet("filter-empty", personal: true) {
            $0.preload(
                query: DesignFixtures.pocockQuery, results: .loaded(DesignFixtures.pocockSearch), skillsSh: .enabled)
            $0.sourceFilter = "github"
        },
        sheet("installs-column", personal: true) {
            $0.preload(
                query: DesignFixtures.pocockQuery, results: .loaded(DesignFixtures.pocockSearch), skillsSh: .enabled,
                selection: AddSkillSamples.pocockSelection)
        },
        // The resizable sheet enlarged: the results column at its 520 pt cap, the preview in the rest.
        sheet("preview-large", boardScope: true, size: AddSkillSamples.largeSheet) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .undecided,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        sheet("progress-large", boardScope: true, previewState: .progress, size: AddSkillSamples.largeSheet) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        // The run before the CLI printed anything: the output box at its full size, with its placeholder.
        sheet("progress-waiting", boardScope: true, previewState: .waiting) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        sheet("progress-waiting-large", boardScope: true, previewState: .waiting, size: Size.addSkillSheetMax) {
            $0.preload(
                query: DesignFixtures.jiraQuery, results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
                selection: AddSkillSamples.jiraPackage, info: AddSkillSamples.jiraInfo)
        },
        Entry(id: "P3-9", state: "success", size: CGSize(width: 1280, height: 800)) {
            AnyView(AddSkillSuccessSample())
        },
    ]

    /// A sheet over api (`boardScope`: the AddSkill board's variant; `snapshot`: another state of it), or over My
    /// Skills when `personal`, at its minimum (the board size) unless `size` says otherwise.
    private static func sheet(
        _ state: String, capable: Bool = false, boardScope: Bool = false, personal: Bool = false,
        previewState: AddSkillSamples.State? = nil, snapshot: ScopeSnapshot? = nil,
        size: CGSize = Size.addSkillSheet,
        _ setUp: @escaping @MainActor @Sendable (SearchStore) -> Void
    ) -> Entry {
        Entry(id: "P3-9", state: state, size: size) {
            AnyView(
                AddSkillSample(
                    capable: capable, previewState: previewState?.sheetState,
                    scope: personal ? .personal : Boot.apiScope,
                    snapshot: snapshot
                        ?? (personal
                            ? DesignFixtures.personal : boardScope ? AddSkillSamples.boardScope : DesignFixtures.api),
                    setUp: setUp))
        }
    }
}

/// The sample values of the Add Skill renders that no fixture file holds.
enum AddSkillSamples {
    /// A run the sheet shows without one: built at render time, so the progress clock reads 0:07.
    enum State: Sendable {
        case progress
        case waiting
        case clashFailure
        case added

        var sheetState: AddSkillSheet.PreviewState {
            switch self {
            case .progress: .running(AddSkillSamples.progress)
            case .waiting: .running(AddSkillSamples.waiting)
            case .clashFailure: .addFailure(AddSkillSamples.clashFailure)
            case .added: .added([AddSkillSamples.added])
            }
        }
    }

    /// The add of `added`: the board's two skills at the version the CLI locked.
    static let added = AddSkillVisit.Added(
        package: jiraPackage, skills: ["jira-syntax", "jira-communication"],
        text: AddSkillCopy.added(
            package: jiraPackage, skills: ["jira-syntax", "jira-communication"], version: "4.2.0"),
        runID: nil)

    /// The enlarged sheet of `preview-large` and `progress-large`.
    static let largeSheet = CGSize(width: 1280, height: 860)
    static let jiraPackage = "netresearch/agent-jira-skill"
    static let kolyaPackage = "kolya/pdf-tools"
    /// The selected row of `installs-column`: the longest name, so its count shows in the selected style too.
    static let pocockSelection = "github:mattpocock/skills/improve-codebase-architecture"
    /// A GitHub source for the Branch rule.
    static let githubJira = "github:netresearch/agent-jira-skill"

    /// `info` of netresearch/agent-jira-skill as Add sees it before it is locked: 4.3.0 is the newest, but `info`
    /// picks 4.2.0 because 4.3.0 is inside the 72h minimum release age (AddSkill board). The fixture file is the
    /// locked package of the detail view (`version` 4.3.0, `locked` true), so this variant differs in those two
    /// keys and `why`.
    static let jiraInfo = DesignFixtures.decode(
        InfoDocument.self,
        json: """
            {"package": "netresearch/agent-jira-skill", "source": "composer",
             "repository": "https://repo.packagist.org/", "version": "4.2.0", "locked": false,
             "description": "Conventions for writing Jira issues and comments the way the team reads them: field syntax, linking, status language, and when not to comment at all.",
             "license": ["MIT"], "abandoned": null,
             "versions": ["4.3.0", "4.2.0", "4.1.2", "4.1.1", "4.0.0"], "requires": {},
             "skills": [
               {"name": "jira-syntax", "description": "Jira field and markup syntax, with examples."},
               {"name": "jira-communication", "description": "How to write comments, status updates and hand-offs."}
             ],
             "why": []}
            """)

    /// AddSkill-States "Name clash": kolya/pdf-tools provides `pdf`, which anthropics/skills already installs in
    /// api. The board names no version or description; these are invented.
    static let kolyaInfo = DesignFixtures.decode(
        InfoDocument.self,
        json: """
            {"package": "kolya/pdf-tools", "source": "composer", "repository": "https://repo.packagist.org/",
             "version": "1.0.2", "locked": false, "description": "PDF tools for agents.", "license": ["MIT"],
             "abandoned": null, "versions": ["1.0.2", "1.0.1"], "requires": {},
             "skills": [{"name": "pdf", "description": "Split, merge and stamp PDF files."}], "why": []}
            """)

    /// The AddSkill board's api scope as the search sees it: atlassian/jira-cli-skill locked (as `jira-cli`),
    /// netresearch/agent-jira-skill not yet added. The api fixture has it the other way round (its jira rows are
    /// the List boards'), so the board's Installed marker needs this variant.
    static var boardScope: ScopeSnapshot {
        apiSnapshot { entries in
            entries.filter { $0["package"] as? String != jiraPackage }
                + [
                    [
                        "package": "atlassian/jira-cli-skill", "skill": "jira-cli", "version": "1.3.0", "state": "ok",
                        "ok": true, "source": "packagist",
                    ]
                ]
        }
    }

    /// The api scope right after Add: jira-syntax and jira-communication installed at 4.2.0, nothing pending for
    /// their package (AddSkill-States "Success": the new rows read Installed).
    static var afterAdd: ScopeSnapshot {
        apiSnapshot(dropOutdated: jiraPackage) { entries in
            entries.map { entry in
                guard entry["package"] as? String == jiraPackage else { return entry }
                var installed = entry
                installed["state"] = "ok"
                installed["ok"] = true
                return installed
            }
        }
    }

    /// The api board's documents with the status entries edited and one package's outdated row dropped.
    static func apiSnapshot(
        dropOutdated package: String? = nil, _ edit: ([[String: Any]]) -> [[String: Any]]
    ) -> ScopeSnapshot {
        ScopeSnapshot(
            status: DesignFixtures.decode(
                StatusDocument.self, json: edited("status.api", key: "entries") { edit($0) }),
            audit: DesignFixtures.decode(AuditDocument.self, "audit.api"),
            doctor: DesignFixtures.decode(DoctorDocument.self, "doctor.api"),
            outdated: DesignFixtures.decode(
                OutdatedDocument.self,
                json: edited("outdated.api", key: "packages") { rows in
                    rows.filter { $0["package"] as? String != package }
                }),
            checkedAt: Date(timeIntervalSinceNow: -4 * 60))
    }

    private static func edited(
        _ fixture: String, key: String, _ edit: ([[String: Any]]) -> [[String: Any]]
    ) -> String {
        let data = Data(DesignFixtures.text(fixture, "json").utf8)
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rows = object[key] as? [[String: Any]]
        else { fatalError("design fixture \(fixture) has no \(key)") }
        object[key] = edit(rows)
        guard let edited = try? JSONSerialization.data(withJSONObject: object) else {
            fatalError("design fixture \(fixture) cannot be written back")
        }
        return String(decoding: edited, as: UTF8.self)
    }

    /// The progress card's lines (AddSkill-States), seven seconds in.
    static var progress: AddSkillProgress.Model {
        AddSkillProgress.Model(
            title: AddSkillCopy.adding(jiraPackage), startedAt: Date().addingTimeInterval(-7),
            lines: DesignFixtures.Transcripts.addJira.map(OutputLine.stdout))
    }

    /// The same run one second in, before its first line.
    static var waiting: AddSkillProgress.Model {
        AddSkillProgress.Model(
            title: AddSkillCopy.adding(jiraPackage), startedAt: Date().addingTimeInterval(-1), lines: [])
    }

    static let notFound = AddSkillCopy.previewFailure(
        DesignFixtures.notFoundFailure.error, spec: PackageSpec.parse(DesignFixtures.notFoundQuery))
    static let blocked = AddSkillCopy.previewFailure(
        DesignFixtures.policyFailure.error, spec: PackageSpec.parse(DesignFixtures.blockedQuery))
    static let unreachable = ErrorCopy.message(for: DesignFixtures.unreachableFailure.error)

    /// The CLI's refusal of a clash at 0.9.4 (`hint` in `src/commands.rs`): the message, then how to rename in
    /// skills.toml, since `add --rename` does not exist yet.
    static let clashFailure = ErrorCopy.message(
        for: .failed(
            code: .problem, message: "skill \"pdf\" is provided by both anthropics/skills and kolya/pdf-tools",
            hint:
                "to install it under another name, set in its entry in skills.toml: rename = { pdf = \"kolya-pdf\" }",
            stderr: ""),
        title: AddSkillCopy.couldNotAdd(kolyaPackage))
}

/// The sheet over a fresh api scope store (the board's data), with the runner the sheet reads from the environment.
private struct AddSkillSample: View {
    @State private var search: SearchStore
    @State private var runner = ActionRunner(queue: MutationQueue())
    private let previewState: AddSkillSheet.PreviewState?

    @MainActor init(
        capable: Bool, previewState: AddSkillSheet.PreviewState?, scope: Scope, snapshot: ScopeSnapshot,
        setUp: (SearchStore) -> Void
    ) {
        let version = Capabilities.minimum
        let capabilities =
            capable
            ? Capabilities(version: version, features: [.addSkill, .addRename]) : Capabilities(version: version)
        let store = ScopeStore(
            scope: scope, client: FixtureCLIClient(), capabilities: capabilities, textReader: Boot.fixtureText)
        store.preload(snapshot: snapshot)
        let search = SearchStore(store: store)
        setUp(search)
        _search = State(initialValue: search)
        self.previewState = previewState
    }

    var body: some View {
        AddSkillSheet(search: search, previewState: previewState)
            .environment(runner)
    }
}

/// AddSkill-States "Success": the sheet has closed, jira-syntax is selected and the toast sits at the bottom of the
/// list column.
private struct AddSkillSuccessSample: View {
    @State private var stores: Boot.Stores

    @MainActor init() {
        let stores = Boot.fixtures(selecting: Boot.apiScope, selection: "jira-syntax")
        stores.app.store(for: Boot.apiScope)?
            .preload(
                snapshot: AddSkillSamples.afterAdd, selection: "jira-syntax",
                detail: SkillDetail(
                    info: Boot.fixtureInfo(for: "jira-syntax"), text: Boot.fixtureText(for: "jira-syntax")))
        stores.runner.announce(
            AddSkillCopy.added(
                package: AddSkillSamples.jiraPackage, skills: ["jira-syntax", "jira-communication"], version: "4.2.0"),
            emphasis: ["jira-syntax", "jira-communication"])
        _stores = State(initialValue: stores)
    }

    var body: some View {
        MainWindow()
            .skillcaskEnvironment(
                app: stores.app, runner: stores.runner, settings: stores.settings, client: stores.client)
    }
}
