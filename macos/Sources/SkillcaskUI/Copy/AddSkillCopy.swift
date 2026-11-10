import Foundation
import SkillcaskCore
import SkillcaskDomain

/// The words of the Add Skill sheet (S8: AddSkill and AddSkill-States boards). Board strings are verbatim except
/// where noted; versions carry no `v` prefix (the `DesignFixtures` decision).
///
/// Invented (no board draws them): `searching`, `loadingPreview`, `idleTitle`, `idleBody`, `noSelection`,
/// `allSkillsAdded`, `selectionKept`, `oneSkillAdded`, `otherSkillsIn`, `addOne`, `showOutput`, `waitingForOutput`,
/// `couldNotAdd`, `added(package:)`, `addedSoFar`, `status(_:count:)`, `summary(done:scope:)`, `done`,
/// `footerPersonal`,
/// `willInstall`, `noResultsBody` for skills.sh on or undecided, the rule label `upToNextMinor`, `branchLabel`,
/// `branchProblem`, the Branch form of `ruleNote`, and the accessibility labels `ruleHint` and `installedHint`.
/// "Exact", "Latest" and "Branch" are Flow-F2's ("Up to next major (default) / Exact / Latest / Branch").
///
/// Declared deviations from Flow-F2: the sheet stays open after an add, so several skills can be added in one
/// visit: the footer says what was added (`status(_:count:)`), and the toast shows once the sheet closes. After one
/// add it is `OutcomeCopy.added` ("Added **jira-syntax** and **jira-communication** (4.2.0)", names semibold, up to
/// two lines), after several `summary(done:scope:)`; the skill list then selects one row only, the last add's first
/// skill ("new rows selected"), since it is single-selection (`ScopeStore.selection` is one id). Branch is offered
/// beside the version rules, so a GitHub repository without tags (no rule shown) keeps the CLI's default branch.
public enum AddSkillCopy {
    // MARK: - Header

    /// `Add Skill to api`, `Add Skill to My Skills` (AddSkill board).
    public static func title(scopeName: String) -> String {
        "Add Skill to \(scopeName)"
    }

    /// The field's accessibility label (AddSkill board, the hidden `<label>`).
    public static let fieldLabel = "Search or enter a source"
    /// The hint at the field's trailing end, before the shapes in mono.
    public static let sourceHint = "or a source:"
    /// The three source shapes, in mono.
    public static let sourceShapes = "vendor/name · github:owner/repo · git:https://…"
    /// Invented: the header's count: `20 results` (`1 result`) unfiltered, `3 of 20 results` while a source filter
    /// hides some.
    public static func results(shown: Int, total: Int) -> String {
        if shown == total {
            return total == 1 ? "1 result" : "\(total) results"
        }
        return "\(shown) of \(total) " + (total == 1 ? "result" : "results")
    }

    /// Invented: the source chips' accessibility group label.
    public static let filterLabel = "Filter by source"

    /// Invented: a source chip's accessibility hint: `Shows only results from skills.sh`.
    public static func filterHint(_ source: String) -> String {
        "Shows only results from \(source)"
    }

    /// Invented: the empty filter's title: `No results from Packagist`.
    public static func noResultsFrom(_ source: String) -> String {
        "No results from \(source)"
    }

    /// Invented: the empty filter's body: what the other sources found (`20 results from other sources.`).
    public static func resultsElsewhere(_ count: Int) -> String {
        switch count {
        case 0: "Nothing matched in any source."
        case 1: "1 result from another source."
        default: "\(count) results from other sources."
        }
    }

    /// `GitHub · blocked by policy`: a repository the scope's policy does not allow.
    public static func blockedByPolicy(_ source: String) -> String {
        "\(source) · blocked by policy"
    }

    public static let sortedByInstalls = "Sorted by installs"

    // MARK: - Consent

    public static let consentTitle = "Also search skills.sh?"
    public static let consentBody =
        "Your search text is sent to skills.sh. Remembered in your config; change it later in Settings › Search."
    public static let consentDecline = "Not now"
    public static let consentAccept = "Search skills.sh too"

    // MARK: - Results

    /// Invented: the spinner while `search` runs.
    public static let searching = "Searching…"
    /// Invented: the results column before anything was typed.
    public static let idleTitle = "Find a skill"
    public static let idleBody = "Type a name to search your sources, or enter a source to add it directly."
    public static let installed = "Installed"
    /// Invented: what VoiceOver reads for the Installed marker; the personal variant names My Skills.
    public static func installedHint(personal: Bool) -> String {
        personal ? "Already in your personal skills.lock" : "Already in this project’s skills.lock"
    }
    public static let blocked = "Blocked by policy"

    /// `Shown so you know it exists; Allowed sources (config.toml) excludes GitHub.`
    public static func blockedDescription(_ source: String) -> String {
        "Shown so you know it exists; Allowed sources (config.toml) excludes \(source)."
    }

    /// `Already in this project as jira-cli.`, appended to an installed result's description; invented for the
    /// personal scope: `Already in My Skills as jira-cli.`
    public static func alreadyIn(_ skills: [String], personal: Bool) -> String {
        "Already in \(personal ? ShellCopy.personalScope : "this project") as \(OutcomeCopy.list(skills))."
    }

    /// Invented: appended to the description of a result that names one skill of a package (skills.sh's
    /// `github:owner/repo/skill`) when that skill is not in the scope but others of the package of that name are:
    /// `This project already has pdf from anthropics/skills.`, `My Skills already has pdf, docx and 3 more from
    /// anthropics/skills.` It names the lock's package, not "this package": the row cannot tell which source the
    /// scope has it from.
    public static func otherSkillsIn(_ skills: [String], package: String, personal: Bool) -> String {
        "\(personal ? ShellCopy.personalScope : "This project") already has \(some(skills)) from \(package)."
    }

    /// `a`, `a and b`, `a, b and c`, then `a, b and 3 more`: a list of names that stays within a line or two.
    static func some(_ names: [String]) -> String {
        names.count <= 3 ? OutcomeCopy.list(names) : "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    /// `4.1k installs`, `38 installs`.
    public static func installs(_ count: Int) -> String {
        "\(compact(count)) installs"
    }

    /// `4100` → `4.1k`, `38` → `38`, `1500000` → `1.5M`: one decimal, dropped when it is zero.
    static func compact(_ count: Int) -> String {
        func scaled(_ value: Double, _ unit: String) -> String {
            let tenths = (value * 10).rounded() / 10
            let text = tenths == tenths.rounded() ? String(Int(tenths)) : String(format: "%.1f", tenths)
            return text + unit
        }
        switch count {
        case ..<1000: return String(count)
        case ..<1_000_000: return scaled(Double(count) / 1000, "k")
        default: return scaled(Double(count) / 1_000_000, "M")
        }
    }

    /// `No results for “kubernetes rollout”`.
    public static func noResults(_ query: String) -> String {
        "No results for “\(query)”"
    }

    /// `in packagist and acme. skills.sh is off; turn it on in Settings › Search to include it.` With skills.sh on
    /// it names it among the sources; undecided, it names the repositories only (invented variants).
    public static func noResultsBody(sources: [String], skillsShOn: Bool?) -> String {
        switch skillsShOn {
        case true?:
            return "in \(OutcomeCopy.list(sources + ["skills.sh"]))."
        case false?:
            return "in \(OutcomeCopy.list(sources)). skills.sh is off; turn it on in Settings › Search to include it."
        case nil:
            return "in \(OutcomeCopy.list(sources))."
        }
    }

    /// `Typing git:https://… skips search and opens the preview straight from the source.`; `source` is drawn in
    /// mono.
    public static func sourceSkipsSearch(_ source: String) -> String {
        "Typing \(source) skips search and opens the preview straight from the source."
    }

    // MARK: - Preview

    /// Invented: the spinner while `info` downloads the package.
    public static let loadingPreview = "Loading package details…"
    /// Invented: the preview pane with nothing selected.
    public static let noSelection = "Select a result to see the skills it provides."
    /// `newest 4.3.0`.
    public static func newest(_ version: String) -> String {
        "newest \(version)"
    }

    /// `4.2.0 will be installed; 4.3.0 is inside your 3 d minimum release age` (board: `v4.2.0 … 72 h`, written
    /// with the policy's own value as the Policy card writes it).
    public static func cooldown(install: String, newest: String, age: String) -> String {
        "\(install) will be installed; \(newest) is inside your \(OverviewCopy.policyValue(age)) minimum release age"
    }

    /// Invented: the newest version is not the one `add` would pick, and no minimum release age explains why.
    public static func willInstall(_ version: String) -> String {
        "\(version) will be installed"
    }

    /// `Skills in this package · 2 selected`.
    public static func skillsHeading(selected: Int) -> String {
        "Skills in this package · \(selected) selected"
    }

    /// Invented: under the provided skills where the CLI has no `add --skill` and the package has no entry yet:
    /// they cannot be unticked.
    public static let allSkillsAdded = "This version of skillcask adds every skill in the package."
    /// Invented: the same place once the package has an entry, and under a skill that is already in the scope:
    /// `add` keeps the skills that entry has, all of them or the ones it selects.
    public static let selectionKept = "Adding it again keeps this package’s current skills."

    /// Invented: under the one skill of a result that names it (`github:owner/repo/skill`): `Only this skill is
    /// added, not the whole package.`; with other skills of the package in the scope, `Only this skill is added,
    /// next to pdf from the same package.`
    public static func oneSkillAdded(alongside others: [String]) -> String {
        others.isEmpty
            ? "Only this skill is added, not the whole package."
            : "Only this skill is added, next to \(some(others)) from the same package."
    }
    public static let versionRule = "Version rule"
    /// The rule button's label: `Up to next major`; `^0.y` reads `Up to next minor`; without a version (Adopt) the
    /// CLI's default names no span.
    static func ruleLabel(_ rule: VersionRule, base: VersionRule.Base?) -> String {
        switch rule {
        case .compatible:
            guard let base else { return cliChooses }
            return base.major == 0 ? upToNextMinor : upToNextMajor
        case .patches: return upToNextMinor
        case .exact: return exact
        case .latest: return latest
        case .branch: return branch
        }
    }

    public static let upToNextMajor = "Up to next major"
    /// Invented: `~4.2.0`, and `^0.3` (which stops at the next minor).
    public static let upToNextMinor = "Up to next minor"
    /// One exact version (Flow-F2).
    public static let exact = "Exact"
    /// `*`: the newest version (Flow-F2).
    public static let latest = "Latest"
    /// A git ref of a GitHub or git source (Flow-F2).
    public static let branch = "Branch"
    /// Invented: the Branch rule's field label and placeholder; the field starts empty and Add waits for a name.
    public static let branchLabel = "Branch name"
    /// Invented: the CLI's default rule when the version it will install is unknown (Adopt): names no span, since
    /// the CLI writes `^major.minor` of what it installs (`^0.y` stops at the next minor).
    public static let cliChooses = "As the command-line tool chooses"
    /// Invented: under the branch field when the CLI would refuse or misread the name (`VersionRule.isValidBranch`).
    public static let branchProblem = "Use letters, digits and . _ / -, in a name that is not a version number."
    /// Invented: the rule button while the package's skills.toml entry keeps its own constraint.
    public static let keptRule = "As in skills.toml"
    /// Invented: VoiceOver's hint on the rule button.
    public static let ruleHint = "Chooses the version range written to skills.toml"

    /// `Written to skills.toml; skills.lock pins 4.2.0 exactly.`
    public static func ruleNote(version: String) -> String {
        "Written to skills.toml; skills.lock pins \(version) exactly."
    }

    /// `ruleNote(version:)`; for Branch (invented) `Written to skills.toml; skills.lock pins the branch’s current
    /// commit.`, and for Latest (invented) `Written to skills.toml; skills.lock pins the version it installs.`:
    /// `*` is resolved by `add` itself, so the preview's `version` is not promised.
    public static func ruleNote(rule: VersionRule, version: String) -> String {
        switch rule {
        case .branch: "Written to skills.toml; skills.lock pins the branch’s current commit."
        case .latest: "Written to skills.toml; skills.lock pins the version it installs."
        case .compatible, .patches, .exact: ruleNote(version: version)
        }
    }

    /// `Will be linked into Claude Code and Cursor.`
    public static func linkedInto(_ agents: [String]) -> String {
        "Will be linked into \(OutcomeCopy.list(agents))."
    }

    // MARK: - Name clash

    public static let renameLabel = "Install the new one as"

    /// `Agents will see it as kolya-pdf; the package keeps its own name in skills.toml.`; `name` in mono.
    public static func renameNote(_ name: String) -> String {
        "Agents will see it as \(name); the package keeps its own name in skills.toml."
    }

    // MARK: - Footer

    /// The footer's note for a project.
    public static let footerProject =
        "Adding writes skills.toml and skills.lock and downloads the package into this project."
    /// Invented: the same note for the personal scope.
    public static let footerPersonal =
        "Adding writes skills.toml and skills.lock and downloads the package into your personal skills."
    /// The default button before the package's skills are known.
    public static let add = "Add"
    /// Invented: one provided skill.
    public static let addOne = "Add 1 Skill"

    /// `Add 2 Skills`; `Add` when the count is unknown.
    public static func addButton(skills: Int?) -> String {
        switch skills {
        case nil, 0?: add
        case 1?: addOne
        case let count?: "Add \(count) Skills"
        }
    }

    /// `Add as kolya-pdf`.
    public static func addAs(_ name: String) -> String {
        "Add as \(name)"
    }

    /// Invented: the footer's close button once something was added in this sheet (Cancel until then, and while a
    /// run is in flight).
    public static let done = "Done"

    /// Invented: beside the last add's words in the footer, from the second add of the sheet on: how many skills
    /// it added so far (`· 3 skills added`).
    public static func addedSoFar(_ total: Int) -> String {
        total == 1 ? "· 1 skill added" : "· \(total) skills added"
    }

    /// Invented: the footer after an add as one sentence, for VoiceOver: the add's own words and the count, when
    /// there is one (`Added pdf (1.4.0) · 3 skills added`).
    public static func status(_ last: String, count: String?) -> String {
        count.map { "\(last) \($0)" } ?? last
    }

    // MARK: - Progress

    /// `Adding netresearch/agent-jira-skill…`: the run's title in the sheet and in Activity.
    public static func adding(_ spec: String) -> String {
        "Adding \(spec)…"
    }

    /// `0:07`: minutes and seconds since the run started.
    public static func elapsed(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(clamped / 60):" + String(format: "%02d", clamped % 60)
    }

    public static let hideOutput = "Hide output"
    /// Invented: the output box's one line until the CLI prints its first (also Adopt's single run).
    public static let waitingForOutput = "Waiting for output…"
    /// Invented: the same link once the output is hidden.
    public static let showOutput = "Show output"

    // MARK: - Outcome

    /// Invented: the add's words when the provided skills are not known (the package lists none), or the CLI
    /// printed no version.
    public static func added(package: String) -> String {
        "Added \(package)"
    }

    /// What an add says, in the footer and in the toast: `Added jira-syntax and jira-communication (4.2.0)`
    /// (`OutcomeCopy.added`); `added(package:)` when the skills or the version are not known.
    static func added(package: String, skills: [String], version: String?) -> String {
        guard let version, !skills.isEmpty else { return added(package: package) }
        return OutcomeCopy.added(skills, version: version)
    }

    /// The same from the CLI's own `added <package> = "<constraint>" (<version>)` line (`src/commands.rs`
    /// `finish_add`): the version it locked, which `info` cannot promise before the run (a GitHub or git ref
    /// locks a commit and prints its first 12 hex digits, `src/github.rs` 278, `src/git.rs` 635).
    static func added(package: String, skills: [String], transcript: [OutputLine]) -> String {
        let version = MutationReport(verbLines: ActionRunner.stdout(of: transcript)).addedVersions.values.first
        return added(package: package, skills: skills, version: version)
    }

    /// Invented: the one toast of a sheet that added more than once, when it closes: `Added 3 skills to api`
    /// (as Adopt's batch: `AdoptCopy.summary(done:scope:)`).
    public static func summary(done: Int, scope: String) -> String {
        done == 1 ? "Added 1 skill to \(scope)" : "Added \(done) skills to \(scope)"
    }

    /// `Couldn’t find acme/jira-triage-v2.`
    public static func couldNotFind(_ spec: String) -> String {
        OutcomeCopy.couldNot("find \(spec)")
    }

    /// Invented: a preview that failed for another reason than a missing package or a policy refusal.
    public static func couldNotLookUp(_ spec: String) -> String {
        OutcomeCopy.couldNot("look up \(spec)")
    }

    /// `GitHub is not an allowed source for this project.` (AddSkill-States); invented for the personal scope:
    /// `GitHub is not an allowed source for your personal skills.`
    public static func notAllowed(_ source: String, personal: Bool) -> String {
        "\(source) is not an allowed source for \(personal ? "your personal skills" : "this project")."
    }

    /// Invented: the title of a failed or cancelled Add, passed to `SheetRun.start(failure:)` (`Couldn’t add acme/jira-triage-v2.`).
    public static func couldNotAdd(_ spec: String) -> String {
        OutcomeCopy.couldNot("add \(spec)")
    }

    /// `Search “jira triage”`.
    public static func searchFor(_ term: String) -> String {
        "Search “\(term)”"
    }

    public static let searchAllowedSources = "Search allowed sources"

    /// What the not-found failure offers to search instead: the package part of the spec in words, without a
    /// trailing version token (`acme/jira-triage-v2` → `jira triage`).
    static func searchTerm(for spec: PackageSpec) -> String {
        let name = spec.package.split(separator: "/").last.map(String.init) ?? spec.package
        var words = name.split { $0 == "-" || $0 == "_" || $0 == "." }.map(String.init)
        if words.count > 1, let last = words.last, last.first == "v", last.dropFirst().allSatisfy(\.isNumber),
            last.count > 1
        {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    /// The preview's failure, titled as AddSkill-States does: `Couldn’t find <spec>.` only when the CLI says the
    /// package is not there (`package … not found in repositories …`, `src/registry.rs`); `<Source> is not an
    /// allowed source for this project.` for a policy refusal, the source taken from the spec (or the result's
    /// repository); `Couldn’t look up <spec>.` for any other problem. The CLI's sentence becomes the reason and
    /// its hint the action. Network, sign-in and other failures keep `ErrorCopy`'s message.
    static func previewFailure(
        _ error: CLIError, spec: PackageSpec?, source: SourceKind? = nil, personal: Bool = false
    ) -> UserMessage {
        let plain = ErrorCopy.message(for: error)
        guard case .failed(.problem, let text, _, _) = error, let spec else { return plain }
        if plain.severity == .warning {
            let kind: SourceKind? =
                switch spec.kind {
                case .github: .github
                case .git: .git
                case .registry: source
                }
            guard let kind else { return plain }
            return ErrorCopy.message(for: error, title: notAllowed(SourceCopy.label(kind), personal: personal))
        }
        return ErrorCopy.message(
            for: error, title: isNotFound(text) ? couldNotFind(spec.base) : couldNotLookUp(spec.base))
    }

    /// The CLI's not-found sentence (`package x/y not found in repositories a, b`), or the boards' wording of it.
    static func isNotFound(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("not found in repositories") || lower.hasPrefix("no package")
    }
}
