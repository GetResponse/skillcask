import Foundation
import SkillcaskCore
import SkillcaskDomain

/// The words of the Scope Overview (Overview, Overview-States and, for the doctor sentences, Health-States): the
/// health strip, the six card titles and their statuses, and the lines a card body draws. CLI lines arrive typed
/// (`DoctorItem`, `PolicyRow.Kind`, `FindingKind`) and leave here as the boards' sentences; views never spell them.
///
/// Text between backticks is a file or folder name drawn in mono (the `EmptyCopy` convention).
public enum OverviewCopy {
    // MARK: - Header

    public static let revealInFinder = ShellCopy.revealInFinder
    public static let agentsLabel = "Agents this project links into"
    public static let checkNow = "Check Now"
    /// Overview-States Loading: the strip while status, doctor and outdated run.
    public static let checkingProject = "Checking this project…"

    // MARK: - Strip words (the number is drawn apart, in primary semibold)

    // The singular strip words ("skill", "needs sync", "needs a decision", "update") have no board source: every
    // board draws plural counts. Invented.

    /// `skills` of `14 skills`.
    public static func skillsWord(_ count: Int) -> String {
        count == 1 ? "skill" : "skills"
    }

    /// `need sync` of `3 need sync`: the error rows.
    public static func needSyncWord(_ count: Int) -> String {
        count == 1 ? "needs sync" : "need sync"
    }

    /// `need a decision` of `5 need a decision`: the warning rows.
    public static func needDecisionWord(_ count: Int) -> String {
        count == 1 ? "needs a decision" : "need a decision"
    }

    /// `not managed` of `12 not managed` (Overview-States "No projects yet"): when every warning row is a skill
    /// another tool installed.
    public static let notManagedWord = "not managed"

    /// `updates` of `2 updates`.
    public static func updatesWord(_ count: Int) -> String {
        count == 1 ? "update" : "updates"
    }

    /// Overview-States Healthy: `All match the lock` behind a green dot. The designer's note says "all synced";
    /// the board wins.
    public static let allMatch = "All match the lock"
    /// Overview-States "Folder without skills.toml": the strip's one segment behind the dashed dot.
    public static let notSetUp = Labels.notSetUp

    /// `Checked 4 min ago`, `Checked just now`.
    public static func checked(_ date: Date, now: Date = .now, timeZone: TimeZone = .current) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<1: return "Checked just now"
        case 1: return "Checked 1 min ago"
        case ..<60: return "Checked \(minutes) min ago"
        default: return "Checked \(Formatters.dayMonth(date, timeZone: timeZone))"
        }
    }

    /// Without a check, the strip says so (no board source).
    public static let updatesNotChecked = "Updates not checked"

    // MARK: - Card titles

    public static let health = "Health"
    public static let updatesTitle = "Updates"
    public static let security = "Security"
    public static let sources = "Sources"
    public static let policy = "Policy"
    public static let agents = "Agents"

    // MARK: - Card lines

    /// One sentence of a card body: an optional lead (a path in mono or a skill name in medium), the words (with
    /// backtick runs in mono) and the quiet hint at the trailing end (`Repair fixes this`).
    public struct Line: Hashable, Sendable {
        public enum Lead: Hashable, Sendable {
            case path(String)
            case name(String)
        }

        public let lead: Lead?
        public let words: String
        public let hint: String?

        public init(lead: Lead? = nil, words: String, hint: String? = nil) {
            self.lead = lead
            self.words = words
            self.hint = hint
        }

        /// The line as one sentence, without the mono marks: what VoiceOver reads and the tests compare.
        public var sentence: String {
            let lead: String? =
                switch self.lead {
                case .path(let path): path
                case .name(let name): name
                case nil: nil
                }
            return EmptyCopy.plain([lead, words].compactMap { $0 }.joined(separator: " "))
        }
    }

    // MARK: - Health card

    /// `2 problems`, `1 problem, 1 warning`, `all good`.
    public static func healthStatus(problems: Int, warnings: Int) -> String {
        if problems == 0 && warnings == 0 {
            return "all good"
        }
        var parts: [String] = []
        if problems > 0 {
            parts.append(problems == 1 ? "1 problem" : "\(problems) problems")
        }
        if warnings > 0 {
            parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings")
        }
        return parts.joined(separator: ", ")
    }

    /// `6 checks passed`.
    public static func checksPassed(_ count: Int) -> String {
        count == 1 ? "1 check passed" : "\(count) checks passed"
    }

    /// `Repaired 2 items`: the header summary after Repair. Invented (Health-States says "Repaired just now"; the
    /// app does not know when doctor --fix ran once the snapshot is rebuilt).
    public static func repaired(_ count: Int) -> String {
        count == 1 ? "Repaired 1 item" : "Repaired \(count) items"
    }

    public static let repair = ShellCopy.repair
    public static let sync = ShellCopy.sync
    public static let healthFootnote =
        "Repair fixes links, the git index and .gitignore. It downloads nothing. Sync installs exactly what "
        + "skills.lock pins."
    /// Health-States: `doctor` has not answered. Invented.
    public static let healthUnknown = "not checked"
    /// The accessibility hint of the passed-checks disclosure. Invented.
    public static let showPassedHint = "Shows the checks that passed"

    /// The board's trailing hint for what fixes a problem.
    public static func hint(_ remedy: DoctorItem.Remedy?) -> String? {
        switch remedy {
        case .repair: "Repair fixes this"
        case .sync: "Sync fixes this"
        case nil: nil
        }
    }

    /// An open problem or warning as the Overview board words it. Board sources: link wrong ("link points
    /// elsewhere"), not installed ("is in skills.lock but not installed"), modified (the Security card's "differs
    /// from the version in the lock"). Every other sentence is invented.
    /// - Parameter remedy: What fixes the item in its doctor answer (`ScopeSnapshot.Doctor.remedy(of:)`); defaults
    ///   to the item's own.
    public static func problem(_ item: DoctorItem, remedy: DoctorItem.Remedy?? = nil) -> Line {
        let hint = hint(remedy ?? item.remedy)
        switch item {
        case .link(let path, let problem):
            return Line(lead: .path(path), words: linkWords(problem), hint: hint)
        case .notOurs(let path):
            return Line(lead: .path(path), words: "was not created by Skillcask; move it away", hint: hint)
        case .strayLinks(let paths):
            return Line(words: "Links left in folders that are no longer agent folders: " + mono(paths), hint: hint)
        case .committed(let paths):
            return Line(words: "Installed skills are committed to git: " + mono(paths), hint: hint)
        case .staleBlock(let file):
            return Line(lead: .path(file), words: "managed block is out of date", hint: hint)
        case .notInstalled(let skill, _):
            return Line(lead: .name(skill), words: "is in `skills.lock` but not installed", hint: hint)
        case .modified(let skill, _):
            return Line(lead: .name(skill), words: changedOnDisk, hint: hint)
        case .shadowed(let skill, let path):
            return Line(lead: .name(skill), words: "is hidden in Claude Code by `\(path)`", hint: hint)
        case .alsoInstalled(let skill, let path):
            return Line(lead: .name(skill), words: "also exists at `\(path)`; the agent may show both", hint: hint)
        case .linksOk, .noStrayLinks, .gitIndexClean, .blockUpToDate, .installedMatch:
            return Line(words: passed(item))
        case .other(let text):
            return Line(words: text)
        }
    }

    private static func linkWords(_ problem: DoctorItem.LinkProblem) -> String {
        switch problem {
        case .wrong: "link points elsewhere"
        case .missing: "link is missing"
        case .foreign: "is a folder Skillcask did not create; move it away"
        case .other(let word): "link \(word)"
        }
    }

    /// What Repair did (Health-States "After Repair": "Relinked .cursor/skills/pdf to the installed copy."). The
    /// other sentences are invented.
    public static func fixed(_ item: DoctorItem) -> Line {
        switch item {
        case .link(let path, _): Line(words: "Relinked `\(path)` to the installed copy.")
        case .staleBlock(let file): Line(words: "Updated the managed block in `\(file)`.")
        case .strayLinks: Line(words: "Removed links from folders that are no longer agent folders.")
        case .committed: Line(words: "Removed installed skills from the git index; the files are kept.")
        default: problem(item)
        }
    }

    /// A passed check (Health-States "All passed"). Board sources: no stray links, git index, every locked skill
    /// installed; links and the managed block are invented.
    public static func passed(_ item: DoctorItem) -> String {
        switch item {
        case .linksOk(let count):
            count == 1 ? "1 agent link points at its installed copy" : "\(count) agent links point at installed copies"
        case .noStrayLinks: "No stray links to removed skills"
        case .gitIndexClean: "Git index does not track installed skills"
        case .blockUpToDate(let file): "The managed block in \(file) is up to date"
        case .installedMatch: "Every locked skill is installed with the locked content"
        default: problem(item).sentence
        }
    }

    // MARK: - Updates card

    /// `2 available`, `none`, or `not checked`.
    public static func updatesStatus(available: Int, checked: Bool) -> String {
        guard checked else { return "not checked" }
        switch available {
        case 0: return "none"
        case 1: return "1 available"
        default: return "\(available) available"
        }
    }

    /// Overview-States Healthy: the collapsed Updates card's trailing text.
    public static let everythingCurrent = "Everything is current"
    public static let reviewAll = "Review All…"
    public static let reviewChanges = DetailCopy.reviewChanges

    /// `legacy-lint: 3.0.0 exists but needs a range change.`
    public static func outsideRange(_ skills: [String], version: String) -> String {
        "\(skills.joined(separator: ", ")): \(version) exists but needs a range change."
    }

    /// `jira-syntax, jira-communication: 4.3.0 becomes available on 30 Oct 2026 (minimum release age 72 h).`; the
    /// age clause only when the policy sets one, the date only when the note carries it.
    public static func cooldown(
        _ skills: [String], update: Update, minimumAge: String?, timeZone: TimeZone = .current
    ) -> String {
        let names = skills.joined(separator: ", ")
        let version = cooldownVersion(update)
        let age = minimumAge.map { " (minimum release age \($0))" } ?? ""
        guard let eligible = update.eligible else {
            return "\(names): \(version ?? Labels.cooldownPlaceholder)\(age)."
        }
        let what = version.map { "\($0) becomes available" } ?? "A newer version becomes available"
        return "\(names): \(what) on \(Formatters.dayMonthYear(eligible, timeZone: timeZone))\(age)."
    }

    /// `4.3.0` from the note `v4.3.0 eligible 2026-…` (`Update.cooldown`).
    private static func cooldownVersion(_ update: Update) -> String? {
        update.cooldown.map { Update.bare($0.version) }
    }

    // MARK: - Security card

    /// `1 changed on disk, 2 findings`, `2 findings`, `no findings`.
    public static func securityStatus(changed: Int, findings: Int) -> String {
        var parts: [String] = []
        if changed > 0 {
            parts.append("\(changed) changed on disk")
        }
        if findings > 0 {
            parts.append(Labels.findings(findings))
        }
        return parts.isEmpty ? "no findings" : parts.joined(separator: ", ")
    }

    /// Overview-States Healthy: the collapsed Security card's trailing text.
    public static let nothingChanged = "Nothing changed on disk"
    public static let showInList = "Show in list"
    public static let changedOnDisk = "differs from the version in the lock"

    /// `asks an agent to download and run a script (line 12)`: the Overview board's words for the finding's rule,
    /// with its line; a rule the board does not word keeps the CLI's message.
    public static func finding(_ kind: FindingKind, message: String, line: Int?) -> String {
        let words: String =
            switch kind {
            case .riskyPattern: "asks an agent to download and run a script"
            case .invisibleCharacter: "contains an invisible character"
            case .modified: changedOnDisk
            case .other: message
            }
        guard let line else { return words }
        return "\(words) (line \(line))"
    }

    // MARK: - Sources card

    public static let sourceName = "Name"
    public static let sourceType = "Type"
    public static let sourceAddress = "Address"
    public static let sourcePolicy = "Policy"
    public static let allowed = "Allowed"
    public static let blocked = "Blocked"

    /// The board's type words for the CLI's repository types (`composer` is printed for Packagist and for a
    /// custom Composer repository alike; the name tells them apart).
    public static func sourceType(_ repository: StatusDocument.Repository) -> String {
        switch repository.type {
        case "composer": repository.name == "packagist" ? "Packagist" : "Custom repository"
        case "github": "GitHub"
        case "git": "Git"
        default: "Custom repository"
        }
    }

    /// `packagist.org`, `github.com`, `skills.acme.example/packages.json`: the URL without its scheme and trailing
    /// slash, with the API hosts of the two public sources named as people know them.
    public static func sourceAddress(_ repository: StatusDocument.Repository) -> String {
        var address = repository.url
        if let range = address.range(of: "://") {
            address = String(address[range.upperBound...])
        }
        if address.hasSuffix("/") {
            address.removeLast()
        }
        switch address {
        case "repo.packagist.org": return "packagist.org"
        case "api.github.com": return "github.com"
        default: return address
        }
    }

    /// `skills.acme.example/packages.json` → `skills.`, `acme.`, `example/`, `packages.`, `json`: the runs an address
    /// may wrap between, never inside one. The board wraps its mono cell at `/` only, but there the cell overflows
    /// its own column; breaking after `.` too keeps the two card columns equal (a deviation from the boards).
    /// A run stays on the line it starts while it fits, so `packagist.org` wraps only in a column too narrow for it.
    public static func addressRuns(_ address: String) -> [String] {
        var runs: [String] = []
        var run = ""
        for character in address {
            run.append(character)
            if character == "/" || character == "." {
                runs.append(run)
                run = ""
            }
        }
        if !run.isEmpty {
            runs.append(run)
        }
        return runs
    }

    /// `GitHub is blocked by Allowed sources, set in config.toml by your organisation. Skills from it stay
    /// installed but cannot be added or updated here.` Several sources and a project-set policy are invented
    /// variants of the board's sentence.
    public static func blockedFootnote(_ sources: [String], policy: ScopeSnapshot.PolicyRow?) -> String? {
        guard !sources.isEmpty else { return nil }
        let one = sources.count == 1
        var origin = ""
        if let policy {
            origin = ", set in \(policy.origin)" + (policy.isEnforced ? " by your organisation" : "")
        }
        return OutcomeCopy.list(sources) + (one ? " is" : " are") + " blocked by \(policyName(.allowSources))"
            + origin + ". Skills from " + (one ? "it" : "them") + " stay installed but cannot be added or updated here."
    }

    /// The name a blocked source goes by in the footnote: the type word for GitHub, else the repository's name.
    public static func blockedName(_ repository: StatusDocument.Repository) -> String {
        repository.type == "github" ? sourceType(repository) : repository.name
    }

    // MARK: - Policy card

    public static let setting = "Setting"
    public static let value = "Value"
    public static let setIn = "Set in"
    public static let enforced = "enforced"
    public static let policyFootnote = "“Enforced” means your organisation set it; the project cannot override it."

    /// The board's names for the policy keys; an unknown key is shown as the CLI prints it.
    public static func policyName(_ kind: ScopeSnapshot.PolicyRow.Kind) -> String {
        switch kind {
        case .minReleaseAge: "Minimum release age"
        case .allowSources: "Allowed sources"
        case .allowRanges: "Ranges allowed"
        case .other(let key): key
        }
    }

    /// `config.toml · enforced`: the Set in cell of an enforced row (the board's dot between file and note).
    public static func enforcedOrigin(_ origin: String) -> String {
        origin + RowCopy.separator + enforced
    }

    /// `72 h` for `72h`, `Yes`/`No` for a boolean, `any` for an unset source list (Overview-States Healthy), else
    /// the value as printed.
    public static func policyValue(_ row: ScopeSnapshot.PolicyRow) -> String {
        if row.kind == .allowSources, row.value == "none" || row.value.isEmpty {
            return "any"
        }
        return policyValue(row.value)
    }

    /// `72 h` for `72h`, `Yes`/`No` for a boolean, else the value as printed.
    public static func policyValue(_ value: String) -> String {
        switch value {
        case "true": return "Yes"
        case "false": return "No"
        default:
            if value.hasSuffix("h"), Int(value.dropLast()) != nil {
                return "\(value.dropLast()) h"
            }
            return value
        }
    }

    /// The Updates card's age clause: `72 h`, nil when the policy sets none (or `0 h`).
    public static func minimumAge(_ policy: [ScopeSnapshot.PolicyRow]) -> String? {
        guard let row = policy.first(where: { $0.kind == .minReleaseAge }), !row.value.isEmpty, row.value != "0h"
        else { return nil }
        return policyValue(row.value)
    }

    // MARK: - Agents card

    public static let agent = "Agent"
    public static let directory = "Directory"

    /// `14 skills are linked into both.` The board only draws two agents; "into it" (one agent), "into all N" and
    /// the singular "1 skill is" are invented, and so is `No skills linked yet.` for none (an empty project).
    public static func linked(skills: Int, agents: Int) -> String {
        guard skills > 0 else { return noneLinked }
        let into = agents == 2 ? "both" : (agents == 1 ? "it" : "all \(agents)")
        return skills == 1 ? "1 skill is linked into \(into)." : "\(skills) skills are linked into \(into)."
    }

    /// Invented: `linked(skills:agents:)` for no skills, instead of "0 skills are linked into both."
    public static let noneLinked = "No skills linked yet."

    /// `Not linked: jira-syntax, sql-review.`: the skills `linked(skills:agents:)` leaves out because they are not
    /// installed or not linked. Invented: the board counts every skill as linked.
    public static func notLinked(_ skills: [String]) -> String {
        "Not linked: \(skills.joined(separator: ", "))."
    }

    /// `One Cursor link is wrong — see Health.`, `2 Kiro links are missing`, and `broken` when the states differ
    /// (or a file skillcask did not create blocks one); the plural is invented.
    public static func brokenLinks(_ states: [AgentReach.State], agent: String) -> String {
        let word =
            Set(states) == [.wrong] ? "wrong" : Set(states) == [.missing] ? "missing" : "broken"
        return states.count == 1
            ? "One \(agent) link is \(word) — see Health." : "\(states.count) \(agent) links are \(word) — see Health."
    }

    // MARK: - Marks

    /// `a`, `b` with each item in mono.
    private static func mono(_ items: [String]) -> String {
        items.map { "`\($0)`" }.joined(separator: ", ")
    }
}
