import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The S5 Security tab over the design fixtures: findings grouped by rule with a fixed explanation, the all-clear
/// rule, which reach groups show, the "Show in file" target, the changed-on-disk actions, the not-audited fallback
/// (Q7) and the Overview's reach half.
@Suite @MainActor struct SecurityTabTests {
    /// An `audit` finding, decoded as the CLI prints it (the Core type has no public memberwise init).
    static func finding(
        _ rule: String, _ path: String, _ line: Int?, _ message: String
    ) throws
        -> AuditDocument.Finding
    {
        let lineValue = line.map(String.init) ?? "null"
        let json =
            #"{"rule":"\#(rule)","path":"\#(path)","# + #""line":\#(lineValue),"message":"\#(message)"}"#
        return try JSONDecoder().decode(AuditDocument.Finding.self, from: Data(json.utf8))
    }

    // MARK: - Grouping

    @Test func findingsAreGroupedByRuleInTheBoardsOrder() throws {
        let finding = { (rule: String, line: Int?) throws in
            try Self.finding(rule, ".skills/n/SKILL.md", line, "m\(line ?? 0)")
        }
        let groups = SecurityContent.groups(
            [
                try finding("invisible-character", 3), try finding("risky-pattern", 12),
                try finding("zz-new-rule", nil), try finding("risky-pattern", 20), try finding("modified", nil),
            ], folder: ".skills/n")
        #expect(
            groups.map(\.kind) == [.modified, .riskyPattern, .invisibleCharacter, .other("zz-new-rule")])
        // One group per rule, the CLI's order kept inside it.
        #expect(groups[1].findings.map(\.location) == ["SKILL.md:12", "SKILL.md:20"])
        #expect(groups[1].findings.map(\.message) == ["m12", "m20"])
        // `modified` draws no finding line: its buttons replace the CLI's `install` hint.
        #expect(groups[0].findings.isEmpty)
        #expect(groups[3].findings.map(\.location) == ["SKILL.md"])
    }

    @Test func myNotesHasTwoGroupsWithPathAndLine() {
        let content = SecurityContent(entry: DesignFixtures.myNotes)
        #expect(content.state == .findings && content.hasTextFindings && !content.isChangedOnDisk)
        #expect(content.groups.map(\.kind) == [.riskyPattern, .invisibleCharacter])
        #expect(content.groups.map { $0.findings.map(\.location) } == [["SKILL.md:17"], ["SKILL.md:3"]])
        #expect(content.groups.map(\.severity) == [.warning, .warning])
        #expect(content.footnote == .rules)
    }

    @Test func eachRuleHasOneFixedExplanation() {
        #expect(SecurityCopy.title(.riskyPattern) == "Risky pattern")
        #expect(SecurityCopy.explanation(.riskyPattern) == "The text asks an agent to run something dangerous.")
        #expect(SecurityCopy.title(.invisibleCharacter) == "Invisible character")
        #expect(
            SecurityCopy.explanation(.invisibleCharacter)
                == "Text an agent sees but you do not. It can hide instructions or reverse what you read.")
        #expect(SecurityCopy.title(.modified) == "Changed on disk")
        #expect(SecurityCopy.explanation(.modified).hasPrefix("The files differ from the version in the lock."))
        #expect(SecurityCopy.title(.other("secret-token")) == "Secret token")
        // The explanation does not depend on the finding: two findings of one rule share it.
        let kinds: [FindingKind] = [.modified, .riskyPattern, .invisibleCharacter, .other("a"), .other("b")]
        #expect(Set(kinds.map(SecurityCopy.explanation)).count == 4)
    }

    // MARK: - States

    @Test func cleanShowsTheAllClearSentenceAlone() {
        let content = SecurityContent(entry: DesignFixtures.commitMessage)
        #expect(content.state == .clean)
        #expect(content.groups.isEmpty && content.reach.isEmpty && !content.hasTextFindings)
        #expect(content.footnote == .scanned(locked: true) && !content.isFootnotePinned)
        let now = Date()
        #expect(
            SecurityCopy.scanned(now.addingTimeInterval(-240), locked: true, now: now)
                == "Scanned 4 min ago. The files match the version in skills.lock.")
    }

    @Test func cleanProjectAndHandWrittenSkillsClaimNoLock() {
        let notes = DesignFixtures.myNotes
        let empty = Reach(commands: [], network: [], paths: [], env: [], scripts: [])
        for kind: SkillEntry.Kind in [.project, .handWritten] {
            let clean = SkillEntry(
                id: notes.id, name: notes.name, kind: kind, source: nil, version: nil, state: .project,
                health: .projectSkill, update: nil, findings: [], path: notes.path, description: nil, reach: empty)
            let content = SecurityContent(entry: clean)
            #expect(content.state == .clean && content.footnote == .scanned(locked: false))
        }
        let now = Date()
        #expect(SecurityCopy.scanned(now.addingTimeInterval(-240), locked: false, now: now) == "Scanned 4 min ago.")
    }

    @Test func onlyTheRulesNoteIsPinnedToTheBottom() {
        // Security board: `margin-top: auto` under the findings; Security-States: right under the callout or card.
        #expect(SecurityContent(entry: DesignFixtures.myNotes).isFootnotePinned)
        #expect(!SecurityContent(entry: DesignFixtures.pdf).isFootnotePinned)
        #expect(!SecurityContent(entry: DesignFixtures.commitMessage).isFootnotePinned)
    }

    @Test func reachOnlyHidesEmptyGroups() {
        let content = SecurityContent(entry: DesignFixtures.pdf)
        #expect(content.state == .reachOnly && content.groups.isEmpty)
        // pdf mentions no environment variable: that group is left out.
        #expect(content.reach.map(\.label) == ["Commands", "Hosts", "Paths", "Scripts"])
        #expect(content.reach.map(\.title) == ["Commands · 3", "Hosts · 1", "Paths · 2", "Scripts · 3"])
        #expect(content.footnote == .mentions && !content.isFootnotePinned)
    }

    @Test func environmentVariablesAreShownWithADollar() {
        let content = SecurityContent(entry: DesignFixtures.deployChecklist)
        #expect(content.reach.map(\.label) == ["Commands", "Hosts", "Environment variables", "Scripts"])
        #expect(content.reach[2].items == ["$KUBECONFIG", "$SLACK_WEBHOOK"])
    }

    /// A row of `kind` with `findings`, on jira-syntax's data.
    static func jira(_ kind: SkillEntry.Kind, _ findings: [AuditDocument.Finding]) -> SkillEntry {
        let jira = DesignFixtures.jiraSyntax
        return SkillEntry(
            id: jira.id, name: jira.name, kind: kind, source: nil, version: jira.version, state: .modified,
            health: .changedOnDisk, update: nil, findings: findings, path: jira.path, description: nil,
            reach: jira.reach)
    }

    static func edited() throws -> AuditDocument.Finding {
        try finding(
            "modified", ".agents/skills/jira-syntax", nil,
            "modified after skillcask installed it; run `skillcask install` to restore")
    }

    static func missing() throws -> AuditDocument.Finding {
        try finding("modified", ".agents/skills/jira-syntax", nil, "not installed")
    }

    @Test func changedOnDiskOffersReinstallFromLockOnly() throws {
        let content = SecurityContent(entry: Self.jira(DesignFixtures.jiraSyntax.kind, [try Self.edited()]))
        #expect(content.state == .findings && content.isChangedOnDisk && !content.hasTextFindings)
        #expect(content.groups.map(\.kind) == [.modified] && content.groups[0].severity == .error)
        #expect(!content.groups[0].isNotInstalled && content.groups[0].title == "Changed on disk")
        #expect(content.footnote == nil)
        #expect(content.restore?.reason == .changed && content.restoreReplacesFiles)
        #expect(SecurityCopy.restoreButton(.changed) == "Reinstall from lock")
    }

    @Test func notInstalledIsItsOwnStateWithoutEditClaims() throws {
        let content = SecurityContent(entry: Self.jira(DesignFixtures.jiraSyntax.kind, [try Self.missing()]))
        let group = content.groups[0]
        #expect(group.kind == .modified && group.isNotInstalled && group.severity == .error)
        #expect(group.title == "Not installed")
        #expect(group.explanation == "skills.lock pins this skill, but it is not installed here.")
        #expect(content.restore == LockRestore(skill: "jira-syntax", reason: .notInstalled, message: "not installed"))
        #expect(SecurityCopy.restoreButton(.notInstalled) == "Install from lock")
        #expect(!content.restoreReplacesFiles)
        let restores = content.restores
        #expect(SecurityCopy.restoreQuestion(restores) == "Install jira-syntax from the lock?")
        #expect(SecurityCopy.restoreConfirm(restores) == "Install")
        #expect(SecurityCopy.restoreMessage(restores) == "Installs the version skills.lock pins.")
        for text in [group.title, group.explanation, SecurityCopy.restoreMessage(restores)] {
            #expect(!text.contains("edit") && !text.contains("not kept"))
        }
    }

    @Test func restoreIsOfferedForLockedSkillsOnly() throws {
        let edited = try Self.edited()
        #expect(SecurityContent(entry: Self.jira(.package("v/jira"), [edited])).restore != nil)
        #expect(SecurityContent(entry: Self.jira(.dependency("acme/dep", via: ["acme/x"]), [edited])).restore != nil)
        for kind: SkillEntry.Kind in [.project, .handWritten, .notManaged(adopt: nil)] {
            let content = SecurityContent(entry: Self.jira(kind, [edited]))
            #expect(content.isChangedOnDisk && content.restore == nil && content.restores.isEmpty)
        }
        // No `modified` finding, no restore even for a package.
        #expect(SecurityContent(entry: DesignFixtures.pdf).restore == nil)
    }

    @Test func theConfirmationNamesEverySkillTheScopeWideInstallRestores() throws {
        // The snapshot's audit reports sql-review missing; jira-syntax is the selected, edited row.
        let snapshot = ScopeSnapshot(
            status: DesignFixtures.decode(StatusDocument.self, "status.api"),
            audit: DesignFixtures.decode(
                AuditDocument.self,
                json: #"{"ok":false,"skills":[{"skill":"sql-review","kind":"package","package":"acme/sql-review","#
                    + #""version":"0.9.2","path":".agents/skills/sql-review","findings":[{"rule":"modified","#
                    + #""path":".agents/skills/sql-review","line":null,"message":"not installed"}],"commands":[],"#
                    + #""network":[],"paths":[],"env":[],"scripts":[]}]}"#),
            doctor: nil, outdated: nil)
        let content = SecurityContent(
            entry: Self.jira(DesignFixtures.jiraSyntax.kind, [try Self.edited()]), snapshot: snapshot)
        #expect(content.restores.map(\.skill) == ["jira-syntax", "sql-review"])
        #expect(content.restores.map(\.reason) == [.changed, .notInstalled] && content.restoreReplacesFiles)
        #expect(SecurityCopy.restoreQuestion(content.restores) == "Reinstall 2 skills from the lock?")
        #expect(SecurityCopy.restoreConfirm(content.restores) == "Reinstall")
        #expect(
            SecurityCopy.restoreMessage(content.restores)
                == "The command-line tool restores every skill that differs from the lock, not only this one.\n"
                + "Changed on disk: jira-syntax.\nNot installed: sql-review.\n\n" + SecurityCopy.reinstallNote)
        // One skill: its name, and the warning alone.
        let alone = SecurityContent(entry: Self.jira(DesignFixtures.jiraSyntax.kind, [try Self.edited()]))
        #expect(SecurityCopy.restoreQuestion(alone.restores) == "Reinstall jira-syntax from the lock?")
        #expect(SecurityCopy.restoreMessage(alone.restores) == SecurityCopy.reinstallNote)
    }

    @Test(.timeLimit(.minutes(1))) func theRestoreRunsAFrozenInstall() async {
        let client = FakeCLIClient()
        let scope = Scope.project(URL(fileURLWithPath: "/tmp/security-tab-tests"))
        await client.lines(.install(frozen: true), in: scope, [])
        let capabilities = Capabilities(version: Capabilities.minimum)
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        let runner = ActionRunner(queue: MutationQueue())
        await runner.restoreFromLock(in: store)
        let commands = await client.commands
        #expect(commands.first == .install(frozen: true))
        #expect(!commands.contains(.install(frozen: false)))
        #expect(runner.activity.first?.command.hasPrefix("skillcask install --frozen") == true)
        #expect(ActionCopy.restored("api") == "Restored api from the lock")
    }

    @Test func reinstallRunsOnlyAfterConfirmation() {
        var gate = SecurityContent.ReinstallGate()
        // A confirm without a question asked runs nothing.
        let unasked = gate.confirm()
        #expect(!unasked)
        gate.request()
        #expect(gate.isAsking)
        gate.cancel()
        let cancelled = gate.confirm()
        #expect(!gate.isAsking && !cancelled)
        gate.request()
        let confirmed = gate.confirm()
        #expect(confirmed && !gate.isAsking)
        // The question is closed after a yes: a second confirm runs nothing.
        let again = gate.confirm()
        #expect(!again)
    }

    @Test func reinstallWarnsThatEditsAreLost() {
        #expect(
            SecurityCopy.reinstallNote
                == "Reinstalling replaces the edited files with the locked version. Your changes are not kept; copy "
                + "them first if you need them.")
        #expect(!SecurityCopy.reinstallNote.contains("adopted"))
    }

    @Test func notManagedWithoutAnAuditRowIsNotAudited() {
        let caveman = DesignFixtures.caveman
        let unaudited = SkillEntry(
            id: caveman.id, name: caveman.name, kind: caveman.kind, source: nil, version: nil, state: caveman.state,
            health: caveman.health, update: nil, findings: [], path: caveman.path, description: nil, reach: nil)
        let content = SecurityContent(entry: unaudited)
        #expect(content.state == .notAudited(notManaged: true) && content.reach.isEmpty && content.footnote == nil)
        // With the planned `auditNotManaged` row the same skill is clean, not "not audited".
        #expect(SecurityContent(entry: caveman).state == .clean)
        // Adopt is `--global` only, so the strip does not offer it.
        #expect(SecurityCopy.notAuditedNotManaged == "The command-line tool scans only the skills it manages.")
        #expect(!SecurityCopy.notAuditedNotManaged.contains("Adopt"))
    }

    // MARK: - Show in file

    @Test func showInFileTargetsSkillMdLinesOnly() throws {
        let groups = SecurityContent.groups(
            [
                try Self.finding("risky-pattern", ".s/x/SKILL.md", 12, "a"),
                try Self.finding("risky-pattern", ".s/x/scripts/run.sh", 4, "b"),
                try Self.finding("invisible-character", ".s/x/SKILL.md", nil, "c"),
            ], folder: ".s/x")
        #expect(groups[0].findings.map(\.target) == [12, nil])
        #expect(groups[0].findings.map(\.location) == ["SKILL.md:12", "scripts/run.sh:4"])
        #expect(groups[1].findings.map(\.target) == [nil])
        #expect(SecurityContent(entry: DesignFixtures.myNotes).groups.flatMap(\.findings).map(\.target) == [17, 3])
    }

    @Test func showInFileOpensContentsAtTheLine() {
        // `SkillDetailView` applies this to its tab and the Contents tab's target line.
        let next = SecurityContent.showInFile(12)
        #expect(next.tab == .contents && next.contentsTarget == 12)
    }

    @Test func pathsOutsideTheFolderStayWhole() {
        #expect(SecurityContent.relative(".skills/a/SKILL.md", to: ".skills/a") == "SKILL.md")
        #expect(SecurityContent.relative(".skills/ab/SKILL.md", to: ".skills/a") == ".skills/ab/SKILL.md")
        #expect(SecurityContent.relative("SKILL.md", to: nil) == "SKILL.md")
    }

    // MARK: - Overview reach half

    @Test func overviewSecurityRowAddsTheReach() {
        #expect(DetailOverviewCopy.mentions(DesignFixtures.pdf.reach) == "3 commands and 1 host")
        #expect(
            DetailOverviewCopy.security(findings: 0, notManaged: false, offline: false, reach: DesignFixtures.pdf.reach)
                == "No findings. Mentions 3 commands and 1 host.")
        let hosts = Reach(commands: [], network: ["a.example", "b.example"], paths: [], env: [], scripts: [])
        #expect(
            DetailOverviewCopy.security(findings: 1, notManaged: true, offline: false, reach: hosts)
                == "1 finding · mentions 2 hosts")
        let one = Reach(commands: ["git"], network: [], paths: ["docs/"], env: [], scripts: [])
        #expect(DetailOverviewCopy.mentions(one) == "1 command and 1 path")
        // Nothing mentioned, or not audited: the findings half alone.
        #expect(DetailOverviewCopy.mentions(DesignFixtures.commitMessage.reach) == nil)
        #expect(DetailOverviewCopy.mentions(nil) == nil)
        let empty = Reach(commands: [], network: [], paths: [], env: [], scripts: [])
        #expect(
            DetailOverviewCopy.security(findings: 0, notManaged: true, offline: false, reach: empty)
                == "No findings. You can read it before adopting.")
        #expect(
            DetailOverviewCopy.security(findings: 0, notManaged: false, offline: true, reach: hosts)
                == "No findings (audit runs locally)")
    }

    @Test func overviewSecurityRowSaysNotAuditedWithoutAnAuditRow() {
        #expect(
            DetailOverviewCopy.security(findings: 0, notManaged: true, offline: false, reach: nil)
                == "Not audited. The command-line tool scans only the skills it manages.")
        #expect(
            DetailOverviewCopy.security(findings: 0, notManaged: false, offline: true, reach: nil)
                == "Not audited. The last scan did not include this skill.")
        let caveman = DesignFixtures.caveman
        let unaudited = SkillEntry(
            id: caveman.id, name: caveman.name, kind: caveman.kind, source: nil, version: nil, state: caveman.state,
            health: caveman.health, update: nil, findings: [], path: caveman.path, description: nil, reach: nil)
        let content = OverviewContent(
            entry: unaudited, detail: nil, snapshot: DesignFixtures.api, scope: Boot.apiScope, isOffline: false,
            agents: DesignFixtures.agentReach(of: unaudited, in: DesignFixtures.api, scope: Boot.apiScope))
        let row = content.place.first { $0.label == DetailOverviewCopy.security }
        #expect(
            row?.value
                == .security(
                    .neutral, "Not audited. The command-line tool scans only the skills it manages.", link: false))
    }

    @Test func overviewOfStandupSummaryMentionsTwoHosts() {
        let content = OverviewContent(
            entry: DesignFixtures.standupSummary, detail: nil, snapshot: DesignFixtures.personal, scope: .personal,
            isOffline: false,
            agents: DesignFixtures.agentReach(
                of: DesignFixtures.standupSummary, in: DesignFixtures.personal, scope: .personal))
        let row = content.place.first { $0.label == DetailOverviewCopy.security }
        #expect(row?.value == .security(.warning, "1 finding · mentions 2 hosts", link: true))
    }
}
