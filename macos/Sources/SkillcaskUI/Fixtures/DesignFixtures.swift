import Foundation
import SkillcaskCore
import SkillcaskDomain

/// The sample data on the design boards (`macos/DESIGN.md`), decoded through the real Core and Domain types so
/// previews and the render tool show exactly what a CLI answer produces. `Fixtures/design/` holds one CLI document
/// per JSON file in the shape `skillcask … --json` prints, `diff.*.txt` in the `diff` text format and `skill.*.md`
/// as SKILL.md files. What no CLI document carries (toasts, activity rows, settings) lives in the plain structs
/// at the end.
///
/// States that are pure presentation have no document: the Overview loading skeleton and the list refreshing at
/// 50 % (the same snapshot behind `Presentation.loading` / a running refresh), the progress views of Review Update
/// and Add Skill (`Transcripts` has their CLI lines) and of the Adopt batch (`adoptBatchProgress` has its rows),
/// the list's "no matches" (`noMatchesQuery` against `api`), "not set up" (`notSetUp`, before any document exists)
/// and the Contents "unreadable" file (`unreadableFile`).
///
/// Declared choices where the boards contradict each other: versions never carry a `v` prefix (Main, Overview,
/// List-States and Versions-States write `4.2.0`, `4.0.1`; Versions, AddSkill, Adopt and the success toast write
/// `v4.2.0`, `v4.0.1`). Versions are taken from the list rows throughout, so the UI never shows both spellings.
public enum DesignFixtures {
    // MARK: - Scopes

    /// `api` (~/work/api) as `Main` and `Overview` show it: 14 skills, 3 need sync, 5 need a decision, 2 updates.
    /// "Update All 2" counts packages (`availableUpdates`), not rows: test-writer shares `anthropics/skills` with
    /// pdf, so `outdated` (one row per package) gives it the same 1.2.0 → 1.4.0 and `attention.updates` is 3.
    /// The "Needs attention" chip is errors + warnings per the designer's note (8 here); the Main board's "5" is a
    /// board inconsistency.
    ///
    /// Planned shape, beyond what the 0.9.4 CLI prints: `status.api.json` gives every row the `source` and
    /// `description` keys (`Capabilities.Feature.statusSource` / `.statusDescription`, not emitted yet) and has a
    /// `not managed` row (caveman) in a project scope, where 0.9.4 reports `not managed` only for the personal
    /// scope (`not_managed` in src/commands.rs returns nothing unless the scope is global). The boards draw both,
    /// so the board states keep this fixture; `apiCLI` is the same scope as 0.9.4 prints it, and the first
    /// preview of each screen built on api uses that.
    public static let api = snapshot(
        status: "status.api", audit: "audit.api", doctor: "doctor.api", outdated: "outdated.api",
        checkedSecondsAgo: 4 * 60)
    /// `api` exactly as the 0.9.4 CLI prints its `status`: no `source` or `description` keys and no project-scope
    /// not managed row (caveman is gone, so safe-refactor's requirer is its package name). The first preview of
    /// the window, the detail and the Overview, so a default render never shows a state that CLI cannot reach.
    public static let apiCLI = snapshot(
        status: "status.api-cli", audit: "audit.api", doctor: "doctor.api", outdated: "outdated.api",
        checkedSecondsAgo: 4 * 60)
    /// `website` (~/work/site), the healthy scope of `Overview-States`: 3 skills, all match the lock.
    public static let website = snapshot(
        status: "status.website", audit: "audit.website", doctor: "doctor.website", outdated: "outdated.website",
        checkedSecondsAgo: 2 * 60)
    /// "My Skills" (~/.config/skillcask/skills): 23 skills, 12 not managed, 11 match the lock. `Adopt-States` lists
    /// commit-message and frontend-design among the adoptable (not managed) skills while `Onboarding-States` shows
    /// them as "Installed": Adopt-States wins, it names their sources and versions.
    public static let personal = snapshot(
        status: "status.personal", audit: "audit.personal", doctor: "doctor.personal",
        outdated: "outdated.personal", checkedSecondsAgo: 0)
    /// `List-States` offline: lock and audit states stay, `updates` is nil so no "→ x.y.z" can show.
    public static let apiOffline = snapshot(
        status: "status.api", audit: "audit.api", doctor: "doctor.api", outdated: nil, checkedSecondsAgo: 4 * 60)
    /// `Versions-States` tag moved: caveman as a managed GitHub package whose v4.1.0 tag moved.
    public static let apiTagMoved = snapshot(
        status: "status.api-tag-moved", audit: "audit.api", doctor: "doctor.api", outdated: "outdated.api-tag-moved",
        checkedSecondsAgo: 4 * 60)
    /// `Running` after Sync failed on sql-review: the other 13 skills are synced.
    public static let apiSynced = snapshot(
        status: "status.api-synced", audit: "audit.api", doctor: "doctor.api", outdated: "outdated.api",
        checkedSecondsAgo: 0)
    /// `Activity` and the `Running` integrity state: pdf updated to 1.4.0, everything synced.
    /// `api` with `outdated` exactly as 0.9.4 prints it: no planned `eligible`/`released` keys, the cooldown only in
    /// the note (`4.3.0 eligible 2026-10-30T09:14:00Z`), so the parse is proven end to end.
    public static let apiNoteOnly = snapshot(
        status: "status.api", audit: "audit.api", doctor: "doctor.api", outdated: "outdated.api-note-only",
        checkedSecondsAgo: 4 * 60)
    public static let apiUpdated = snapshot(
        status: "status.api-updated", audit: "audit.api", doctor: "doctor.api-repaired",
        outdated: "outdated.api-updated", checkedSecondsAgo: 60)
    /// `Health-States` after Repair: two items repaired, the download still missing.
    public static let apiRepaired = snapshot(
        status: "status.api", audit: "audit.api", doctor: "doctor.api-repaired", outdated: "outdated.api",
        checkedSecondsAgo: 2)
    /// Per-skill agent badges (no board; `AgentIndex`): `status --json` and `doctor --json` exactly as the 0.10.2 CLI
    /// printed them for a copy of the click-through demo (`[agents] targets = ["claude", "kiro", "codex",
    /// "./tools/skills"]`; `codex` reads the store, so `dirs` has three entries). handy-notes (hand-written) reaches
    /// every agent; review-notes misses its Kiro link; sql-style has a wrong Claude Code link; a folder skillcask did
    /// not create blocks release-checklist in `tools/skills`; notes lost its store link (`not linked`, and `doctor`
    /// then calls every target link wrong); jira-syntax is locked but not installed; acme/gone is a package-only row
    /// with no claim. No audit or outdated.
    public static let agents = snapshot(
        status: "status.agents", audit: nil, doctor: "doctor.agents", outdated: nil, checkedSecondsAgo: 60)
    /// `agents` before `doctor` answered (the first, status-only load): every link is unchecked.
    public static let agentsUnchecked = snapshot(
        status: "status.agents", audit: nil, doctor: nil, outdated: nil, checkedSecondsAgo: 0)
    /// The healthy single-target website with changelog's Claude Code link missing: the one case a single-target
    /// scope draws a badge.
    public static let websiteLinkMissing = snapshot(
        status: "status.website", audit: "audit.website", doctor: "doctor.website-link-missing",
        outdated: "outdated.website", checkedSecondsAgo: 60)
    /// `List-States` empty after Set Up: skills.toml exists, no skills yet.
    public static let emptyAfterSetUp = snapshot(
        status: "status.empty", audit: nil, doctor: nil, outdated: nil, checkedSecondsAgo: 0)

    /// The audit documents behind `api` and `personal`, decoded on their own for the Security tab's reach lists.
    /// Their `kind: "not managed"` rows (caveman in api; caveman, pdf and standup-summary in personal) are the
    /// planned `Capabilities.Feature.auditNotManaged` shape (Q7): a 0.9.4 `audit` lists lock, hand-written and
    /// project skills only, so on that CLI these rows are absent and the Security tab of a not-managed skill
    /// shows its "not audited" fallback. The boards need them for `Detail-States` ("No findings. You can read it
    /// before adopting.", "1 finding · mentions 2 hosts") and the Overview's "Security · 1 finding".
    public static let apiAudit = decode(AuditDocument.self, "audit.api")
    public static let personalAudit = decode(AuditDocument.self, "audit.personal")

    // MARK: - Skills (`Main`, `Detail-States`)

    /// Its audit reach lists 2 paths as on `Security-States`; the Main detail's "Mentions 3 commands and 1 path"
    /// is a board inconsistency.
    public static let pdf = entry("pdf", in: api)
    public static let jiraSyntax = entry("jira-syntax", in: api)
    public static let jiraCommunication = entry("jira-communication", in: api)
    public static let deployChecklist = entry("deploy-checklist", in: api)
    public static let sqlReview = entry("sql-review", in: api)
    public static let myNotes = entry("my-notes", in: api)
    /// Planned shape: a not managed row in a project scope, which the 0.9.4 CLI never reports (`api`); the
    /// personal scope's `personalCaveman` is the reachable one.
    public static let caveman = entry("caveman", in: api)
    public static let safeRefactor = entry("safe-refactor", in: api)
    public static let legacyLint = entry("legacy-lint", in: api)
    public static let testWriter = entry("test-writer", in: api)
    public static let reviewPr = entry("review-pr", in: api)
    public static let commitMessage = entry("commit-message", in: api)
    public static let apiDocs = entry("api-docs", in: api)
    public static let changelog = entry("changelog", in: api)
    /// `Detail-States` "Info unavailable — offline": status-known fields only, no `InfoDocument`.
    public static let commitMessageOffline = entry("commit-message", in: apiOffline)
    /// Not managed, source unknown (`Detail-States`, `Adopt-States`): `kind == .notManaged(adopt: nil)`. The
    /// known-source variant is `caveman` with `adopt: "github:juliusbrussee/caveman"`; the CLI's `info <skill>`
    /// knows only package, project and hand-written skills, so neither state has an info document.
    public static let standupSummary = entry("standup-summary", in: personal)
    public static let meetingPrep = entry("meeting-prep", in: personal)
    public static let frontendDesign = entry("frontend-design", in: personal)
    public static let personalCaveman = entry("caveman", in: personal)
    public static let personalPdf = entry("pdf", in: personal)
    /// `Versions-States` tag moved: caveman as a managed package.
    public static let managedCaveman = entry("caveman", in: apiTagMoved)

    // MARK: - Agent badges (`agents`)

    public static let agentsHandyNotes = entry("handy-notes", in: agents)
    public static let agentsReviewNotes = entry("review-notes", in: agents)
    public static let agentsSqlStyle = entry("sql-style", in: agents)
    public static let agentsReleaseChecklist = entry("release-checklist", in: agents)
    public static let agentsNotes = entry("notes", in: agents)
    public static let agentsJiraSyntax = entry("jira-syntax", in: agents)

    /// The project-scope `AgentIndex` of a fixture snapshot, as `ScopeStore` builds it.
    public static func agentIndex(
        _ snapshot: ScopeSnapshot, isGlobal: Bool = false, check: AgentIndex.LinkCheck? = nil
    ) -> AgentIndex {
        AgentIndex(snapshot: snapshot, isGlobal: isGlobal, check: check)
    }

    /// The reach of `entry` in a fixture snapshot, as `ScopeStore.agentReach(for:)` returns it.
    public static func agentReach(of entry: SkillEntry, in snapshot: ScopeSnapshot, scope: Scope) -> AgentReach {
        agentIndex(snapshot, isGlobal: scope.isPersonal).reach(of: entry)
    }

    // MARK: - Updates (`Versions`, `Versions-States`, `ReviewUpdate`)

    /// Update within range: 1.2.0 → 1.4.0, released 24 Oct 2026.
    public static let pdfUpdate = update("anthropics/skills", in: api)
    public static let reviewPrUpdate = update("acme/review-pr", in: api)
    /// Waiting for the minimum release age: 4.3.0 released 28 Oct 2026, eligible 30 Oct 2026. The board's own
    /// arithmetic is off: released 28 Oct 09:14 plus the 72 h policy is 31 Oct, but every board says "30 Oct"
    /// (48 h); both dates are kept verbatim, the app derives nothing from them. `within` is 4.3.0, as the CLI
    /// prints it: `outdated` computes `within` without the cooldown and names that version in the note
    /// (`src/commands.rs` 1741–1747), so the row is a cooldown, not an update (`Update.cooldown`).
    public static let jiraCommunicationUpdate = update("netresearch/agent-jira-skill", in: api)
    /// Major release outside the range: 3.0.0 exists, ^2.0 stops at 2.3.1.
    public static let legacyLintUpdate = update("acme/lint", in: api)
    /// Up to date: 3.1.0 is the newest version.
    public static let commitMessageUpdate = update("acme/commit", in: api)
    /// Tag moved: `tag 4.0.1 moved from a81f2c0d4e9b to 3fd09e1c7a52`, beside the update 4.0.1 → 4.1.0. The CLI
    /// names the LOCKED version's tag (`moved_tag` in `src/commands.rs` 1775–1779; the board says v4.1.0) and
    /// prints 12-character commit prefixes; the board shortens them to 7 (`a81f2c0`, `3fd09e1`).
    public static let cavemanTagMoved = update("juliusbrussee/caveman", in: apiTagMoved)

    // MARK: - Info (`Main` detail, `Detail-States`, `AddSkill` preview)

    public static let pdfInfo = decode(InfoDocument.self, "info.package.anthropics-skills")
    public static let jiraPackageInfo = decode(InfoDocument.self, "info.package.netresearch-agent-jira-skill")
    /// Abandoned: use acme/lint2 instead.
    public static let legacyLintInfo = decode(InfoDocument.self, "info.package.acme-lint")
    /// Dependency: required by juliusbrussee/caveman (4.0.1).
    public static let safeRefactorInfo = decode(InfoDocument.self, "info.package.juliusbrussee-safe-refactor")
    public static let commitMessageInfo = decode(InfoDocument.self, "info.package.acme-commit")
    public static let myNotesInfo = decode(InfoDocument.self, "info.skill.my-notes")

    // MARK: - Search (`AddSkill`, `AddSkill-States`)

    public static let jiraQuery = "jira"
    /// 7 results from Packagist, acme and GitHub (blocked); skills.sh undecided, so the consent card shows. The
    /// "Installed" marker on atlassian/jira-cli-skill comes from the lock: only `personal` has a jira-cli row, the
    /// board's `api` list does not.
    public static let jiraSearch = decode(SearchDocument.self, "search.jira")
    public static let noResultsQuery = "kubernetes rollout"
    /// The source filter's search, as the CLI prints it for the personal scope (Packagist and GitHub allowed,
    /// skills.sh on): 2 Packagist packages (no install count, `installs` is skills.sh's), nothing from GitHub, and
    /// skills.sh's 20 (its API's cap) with 4- and 5-digit counts behind long `github:` names.
    public static let pocockQuery = "pocock"
    public static let pocockSearch = decode(SearchDocument.self, "search.pocock")
    public static let noResults = decode(SearchDocument.self, "search.empty")
    /// `List-States` filtered, no matches: a query, not a document.
    public static let noMatchesQuery = "postgres"
    /// `AddSkill` typed as a source: skips search and opens the preview.
    public static let sourceQuery = "git:https://git.acme.example/sql-review.git"

    // MARK: - Diffs (`ReviewUpdate`, `ReviewUpdate-States`, `Security-States`)

    /// pdf 1.2.0 → 1.4.0: 4 files, +31 −9, one risky pattern and one invisible character in SKILL.md. The board's
    /// "4 files" leaves out the binary `assets/sample.pdf` (5 files listed) and "+31 −9" leaves out the three `-`
    /// lines of the removed `LEGACY.md`: counts are per text file with a hunk. The first hunk's header reads
    /// `@@ -8,11 +8,16 @@` because the board's `-8,9 +8,15` does not match the 11 old / 16 new lines it shows.
    public static let pdfDiff = UnifiedDiff(text: text("diff.pdf", "txt"))
    /// Update All: both packages in one `diff` run.
    public static let updateAllDiff = UnifiedDiff(text: text("diff.pdf", "txt") + text("diff.review-pr", "txt"))
    /// Nothing to update.
    public static let upToDateDiff = UnifiedDiff(text: text("diff.up-to-date", "txt"))
    /// Changed on disk: the lock against the folder, 2 files changed, 1 added.
    public static let deployChecklistDiff = UnifiedDiff(text: text("diff.deploy-checklist", "txt"))

    // MARK: - Contents (`Contents`, `Contents-States`)

    /// The Contents board's Markdown: front matter with four keys, then two `##` headings, two paragraphs, a
    /// numbered list and a closing paragraph, with a raw U+202E on line 11 that `parse` escapes. The audit finding
    /// says line 3 (the board's number); the front matter takes lines 1–6 and the board shows the character in the
    /// body, so the two cannot agree. The curl line is line 17 as the finding says (the boards' "line 12" cannot
    /// hold with the board's blocks under a six-line front matter). `myNotesFile.bytes` is the board's "1.8 KB",
    /// not the size of this file.
    public static let myNotesText = SkillText.parse(text("skill.my-notes", "md"))
    /// my-notes with four more sections between its two, so the curl line (49) sits below the fold of the
    /// Contents preview: "Show in file" has to scroll to it.
    public static let myNotesLongText = SkillText.parse(text("skill.my-notes.long", "md"))
    /// `myNotes` with its findings on the lines of `myNotesLongText`.
    public static let myNotesLong = SkillEntry(
        id: myNotes.id, name: myNotes.name, kind: myNotes.kind, source: myNotes.source, version: myNotes.version,
        state: myNotes.state, health: myNotes.health, update: myNotes.update,
        findings: decode(
            [AuditDocument.Finding].self,
            json: """
                [{"rule": "risky-pattern", "path": ".skills/my-notes/SKILL.md", "line": 49,
                  "message": "downloads code into a shell"},
                 {"rule": "invisible-character", "path": ".skills/my-notes/SKILL.md", "line": 3,
                  "message": "U+202E RIGHT-TO-LEFT OVERRIDE"}]
                """),
        path: myNotes.path, description: myNotes.description, reach: myNotes.reach)
    public static let pdfText = SkillText.parse(text("skill.pdf", "md"))
    /// Too large: the first 256 KiB only.
    public static let apiDocsText = SkillText.parse(text("skill.api-docs", "md"), truncated: true)
    public static let myNotesFile = SkillFile(name: "SKILL.md", bytes: 1843, modified: date("2026-10-03T00:00:00Z"))
    public static let pdfFile = SkillFile(name: "SKILL.md", bytes: 6348, modified: nil)
    public static let apiDocsFile = SkillFile(name: "SKILL.md", bytes: 1_363_148, modified: nil)

    // MARK: - Health (`Health-States`)

    /// Doctor lines keep the CLI wording of the 0.9.4 capture (`links: N ok`, `<dir>: link wrong`, `<store>/<n>:
    /// not installed (<pkg>); run \`skillcask install\``, `.gitignore: stale managed block`); the app's Copy layer
    /// rewords them. The board's prose (".cursor/skills/pdf points at ../../old/pdf, not at the installed copy.",
    /// "jira-syntax is in skills.lock but its folder is missing.") is that copy, and the link target
    /// `../../old/pdf` exists in no CLI document (Q6). The board's warning ".gitignore does not exclude
    /// .skillcask/cache/" is a stale managed block, which the CLI reports under `problems` (its `warnings` are
    /// shadowed skill names only). The CLI also reports, in `link_plan` order (skills sorted, then targets), a
    /// `<target>/<skill>: link missing` per agent target for each skill that is not installed (jira-syntax and
    /// sql-review, as `status.api.json` says), prints the `not installed` lines after the gitignore check, and
    /// prints `links: N ok` only when no link is open; and `--fix` relinks only skills whose folder exists. So
    /// `doctor.api.json` has 8 problems and no warning where the board shows "2 problems, 1 warning", and the
    /// repaired document fixes the pdf link and the block and leaves the four links and the two downloads, 6 open.
    /// A check `--fix` repaired goes to `fixed`, not to
    /// `passed` (the block, the git index and stray links are `passed` only when they already matched), so the
    /// board's "6 / 7 / 8 checks passed" become 2 / 2 / 5 lines; only `personal` ("5 checks passed") matches.
    public static let healthProblems = decode(DoctorDocument.self, "doctor.api")
    public static let healthRepaired = decode(DoctorDocument.self, "doctor.api-repaired")
    public static let healthAllPassed = decode(DoctorDocument.self, "doctor.all-passed")

    // MARK: - Projects and presentation (`Overview-States`, `Onboarding`, `Onboarding-States`)

    public static let projects = decode(ProjectsDocument.self, "projects")
    public static let noProjects = decode(ProjectsDocument.self, "projects.empty")
    public static let cliMissing = Presentation.cliMissing(searched: Onboarding.searched)
    public static let cliTooOld = Presentation.cliTooOld(found: Version(0, 7, 2), needs: Version(0, 9, 0))
    public static let notSetUp = Presentation.noManifest
    /// The agents Set Up would link in `infra-playbooks` (Overview-States "Folder without skills.toml").
    public static let notSetUpAgents = [
        EmptyCopy.Agent(name: "Claude Code", folder: ".claude/"), EmptyCopy.Agent(name: "Cursor", folder: ".cursor/"),
    ]

    // MARK: - Outcomes (`Running`, `AddSkill-States`)

    public static let updatedPdf = MutationReport(verbLines: "updated anthropics/skills 1.2.0 -> 1.4.0\n")
    public static let addedJira = MutationReport(
        verbLines: "added netresearch/agent-jira-skill\ninstalled jira-syntax\ninstalled jira-communication\n")
    public static let updatedToast = Toast(message: "Updated pdf to 1.4.0", action: "Show details")
    public static let addedToast = Toast(
        message: "Added jira-syntax and jira-communication (4.2.0)", action: "Show details")

    // MARK: - Failures (`Running`, `ReviewUpdate-States`, `AddSkill-States`, `Contents-States`)

    public static let signInBanner = Banner(
        title: "Couldn’t sync sql-review.",
        error: .failed(
            code: .signIn, message: "The source git.acme.example needs you to sign in.",
            hint: "Add a token in Settings › Updates, then Sync again. The other 13 skills were synced.", stderr: ""))
    public static let integrityBanner = Banner(
        title: "Integrity failure while updating review-pr.",
        error: .failed(
            code: .integrity, message: "The downloaded content did not match the lock. Nothing was changed.",
            hint:
                "This can mean the source was tampered with. Tell whoever maintains acme/review-pr before trying again.",
            stderr: ""))
    public static let fetchFailure = Banner(
        title: "Couldn’t fetch the changes for 1.4.0",
        error: .failed(
            code: .network, message: "github.com did not answer.",
            hint: "Check your connection and try again. Nothing was changed; pdf 1.2.0 stays installed.",
            stderr: ""))
    public static let notFoundQuery = "acme/jira-triage-v2"
    public static let notFoundFailure = Banner(
        title: "Couldn’t find acme/jira-triage-v2.",
        error: .failed(
            code: .problem, message: "No package with that name in packagist or acme.",
            hint: "Check the spelling, or search for “jira triage” instead.", stderr: ""))
    public static let blockedQuery = "github:ankit/jira-helper"
    public static let policyFailure = Banner(
        title: "GitHub is not an allowed source for this project.",
        error: .failed(
            code: .problem,
            message: "Allowed sources are packagist, acme, set in config.toml and enforced by your organisation.",
            hint: "Ask the person who maintains config.toml, or look for the package on an allowed source.",
            stderr: ""))
    public static let nameClash = NameClash(
        existing: "pdf", existingPackage: "anthropics/skills", newPackage: "kolya/pdf-tools",
        suggestedName: "kolya-pdf")
    public static let unreachableFailure = Banner(
        title: "Couldn’t reach packagist.",
        error: .failed(
            code: .network, message: "Couldn’t reach packagist.",
            hint: "Check your connection and try again; acme answered.", stderr: ""))
    public static let unreadableFile = Banner(
        title: "Can’t read SKILL.md",
        error: .failed(
            code: .file,
            message: "The file is missing or not readable by your user. Check the folder, then Check again.",
            hint: "Nothing was changed.", stderr: "~/work/api/.claude/skills/deploy-checklist/SKILL.md"))

    // MARK: - Plain values

    /// A sidebar row: the scope's name and the path shown under it.
    public struct ScopeLabel: Hashable, Sendable {
        public let name: String
        public let path: String
    }

    public static let apiScope = ScopeLabel(name: "api", path: "~/work/api")
    public static let websiteScope = ScopeLabel(name: "website", path: "~/work/site")
    /// Not set up: a folder without skills.toml.
    public static let infraPlaybooksScope = ScopeLabel(name: "infra-playbooks", path: "~/work/infra")
    public static let personalScope = ScopeLabel(name: "My Skills", path: "~/.config/skillcask/skills")

    /// What the Contents toolbar says about the file; `SkillText` carries the text only.
    public struct SkillFile: Hashable, Sendable {
        public let name: String
        public let bytes: Int
        public let modified: Date?
    }

    public struct Toast: Hashable, Sendable {
        public let message: String
        public let action: String
    }

    /// The failure banner: one sentence what (`title`), the CLI's message and hint for what to do.
    /// A refresh in which `audit` and `doctor` could not read skills.lock while `status` answered: the earlier
    /// findings and Health stay, the Overview header says so. Invented (no board draws it).
    @MainActor static let partialFailure = ScopeStore.PartialFailure(
        failed: [.audit, .doctor], kept: [.audit, .doctor],
        error: .failed(
            code: .file, message: "cannot read skills.lock: Permission denied (os error 13)", hint: nil,
            stderr: "error: cannot read skills.lock: Permission denied (os error 13)\n"))

    public struct Banner: Hashable, Sendable {
        public let title: String
        public let error: CLIError
    }

    /// `AddSkill-States` name clash: the rename field is prefilled with `suggestedName`.
    public struct NameClash: Hashable, Sendable {
        public let existing: String
        public let existingPackage: String
        public let newPackage: String
        public let suggestedName: String
    }

    /// One row of the Activity drawer (`Activity`): plain-words title, the command, how it exited, how long it took.
    public struct ActivityRun: Hashable, Sendable {
        public let title: String
        public let command: String
        public let status: ExitStatus
        public let seconds: Double
        public let startedAt: String
        public let transcript: [String]
    }

    /// `Activity`: this session · 6 runs, newest first.
    public static let activity: [ActivityRun] = [
        ActivityRun(
            title: "Updated pdf to 1.4.0", command: "skillcask update anthropics/skills --json", status: .exited(0),
            seconds: 3.2, startedAt: "14:02",
            transcript: Transcripts.updatePdf + [
                #"{"updated":[{"skill":"pdf","from":"1.2.0","to":"1.4.0"}],"warnings":[]}"#
            ]),
        ActivityRun(
            title: "Reviewed changes for pdf 1.2.0 → 1.4.0", command: "skillcask diff -- anthropics/skills",
            status: .exited(0), seconds: 1.8, startedAt: "14:01", transcript: []),
        ActivityRun(
            title: "Couldn’t sync sql-review", command: "skillcask install", status: .exited(2), seconds: 1.1,
            startedAt: "13:58", transcript: []),
        ActivityRun(
            title: "Checked api", command: "skillcask doctor --json", status: .exited(0), seconds: 0.4,
            startedAt: "13:57", transcript: []),
        ActivityRun(
            title: "Checked for updates", command: "skillcask outdated --json", status: .exited(0), seconds: 0.9,
            startedAt: "13:56", transcript: []),
        ActivityRun(
            title: "Opened api", command: "skillcask status --json", status: .exited(0), seconds: 0.3,
            startedAt: "13:55", transcript: []),
    ]

    /// One row of the Adopt batch progress (`Adopt-States`): the outcome as shown and how long it took, nil while
    /// the item is still running or waiting.
    public struct AdoptRow: Hashable, Sendable {
        public let skill: String
        public let result: String
        public let seconds: Double?
    }

    /// `Adopt-States` "Batch progress — per-item result": adopting 9 skills, 4 of 9 done.
    public static let adoptBatchProgress: [AdoptRow] = [
        AdoptRow(skill: "caveman", result: "Adopted 4.0.1 · copy kept", seconds: 2.1),
        AdoptRow(skill: "pdf", result: "Adopted 1.4.0 · copy kept", seconds: 3.4),
        AdoptRow(skill: "frontend-design", result: "Adopted 0.6.0 · your copy differed; kept aside", seconds: nil),
        AdoptRow(skill: "commit-message", result: "Downloading 3.1.0 (packagist)…", seconds: nil),
        AdoptRow(skill: "sql-review", result: "Waiting", seconds: nil),
        AdoptRow(skill: "changelog", result: "Waiting", seconds: nil),
    ]

    /// The CLI's output lines while a command runs (`ReviewUpdate-States`, `AddSkill-States`, `Running`).
    public enum Transcripts {
        public static let updatePdf = [
            "Resolving anthropics/skills (^1.2)… 1.4.0",
            "Downloading 1.4.0 (github)… 142 KB",
            "Verifying content hash… ok",
            "Writing skills.lock",
            "Linking pdf → .claude/skills",
        ]
        public static let addJira = [
            "Resolving netresearch/agent-jira-skill (^4.2)… 4.2.0",
            "  4.3.0 skipped: released 28 Oct, minimum release age 72 h",
            "Downloading 4.2.0 (packagist)… 86 KB",
            "Verifying content hash… ok",
            "Writing skills.toml, skills.lock",
            "Linking jira-syntax → .claude/skills",
            "Linking jira-communication → .claude/skills",
        ]
        public static let sync = ["Installing jira-syntax 4.2.0 (packagist)…", "Verifying content hash… ok"]
    }

    /// `Onboarding`, `Onboarding-States`: where the app looks and what to run.
    public enum Onboarding {
        public static let searched = ["/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin"]
        public static let installCommand = "brew install puniserv/tap/skillcask"
        public static let upgradeCommand = "brew upgrade skillcask"
        public static let foundPath = "/opt/homebrew/bin/skillcask"
    }

    /// `Settings`, `Settings-States`.
    public struct Settings: Hashable, Sendable {
        public let toolPath: String
        public let toolVersion: Version
        public let recentProjects: [ScopeLabel]
        public let searchSkillsSh: Bool
        public let checkOnOpen: Bool
        public let gitHubSignedIn: Bool
        public let environment: [EnvironmentVariable]
        public let configPath: String
        public let adoptedPath: String
        public let adoptedSummary: String
    }

    public struct EnvironmentVariable: Hashable, Sendable {
        public let name: String
        public let value: String
    }

    public static let settings = Settings(
        toolPath: Onboarding.foundPath, toolVersion: Version(0, 9, 4),
        recentProjects: [apiScope, websiteScope, infraPlaybooksScope], searchSkillsSh: true, checkOnOpen: true,
        gitHubSignedIn: false,
        environment: [
            EnvironmentVariable(name: "SKILLCASK_CACHE_DIR", value: "~/Library/Caches/skillcask"),
            EnvironmentVariable(name: "HTTPS_PROXY", value: "http://proxy.acme.example:3128"),
        ],
        configPath: "~/.config/skillcask/config.toml", adoptedPath: "~/.config/skillcask/adopted/",
        adoptedSummary: "4 folders · 1.2 MB")

    // MARK: - Loading

    static func snapshot(
        status: String, audit: String?, doctor: String?, outdated: String?, checkedSecondsAgo: Double
    ) -> ScopeSnapshot {
        ScopeSnapshot(
            status: decode(StatusDocument.self, status), audit: audit.map { decode(AuditDocument.self, $0) },
            doctor: doctor.map { decode(DoctorDocument.self, $0) },
            outdated: outdated.map { decode(OutdatedDocument.self, $0) },
            checkedAt: Date(timeIntervalSinceNow: -checkedSecondsAgo))
    }

    static func entry(_ id: String, in snapshot: ScopeSnapshot) -> SkillEntry {
        guard let entry = snapshot.entry(id: id) else { fatalError("design fixture has no skill named \(id)") }
        return entry
    }

    static func update(_ package: String, in snapshot: ScopeSnapshot) -> Update {
        guard let update = snapshot.updates?.first(where: { $0.package == package }) else {
            fatalError("design fixture has no outdated row for \(package)")
        }
        return update
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url(name, "json")))
        } catch {
            fatalError("design fixture \(name).json does not decode as \(type): \(error)")
        }
    }

    /// A small document written inline, for a variant whose difference from its fixture file is a few values.
    static func decode<T: Decodable>(_ type: T.Type, json: String) -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            fatalError("inline design fixture does not decode as \(type): \(error)")
        }
    }

    static func text(_ name: String, _ ext: String) -> String {
        do {
            return try String(contentsOf: url(name, ext), encoding: .utf8)
        } catch {
            fatalError("design fixture \(name).\(ext) is not UTF-8 text: \(error)")
        }
    }

    static func date(_ iso8601: String) -> Date {
        do {
            return try Date(iso8601, strategy: .iso8601)
        } catch {
            fatalError("design fixture date \(iso8601) is not RFC 3339: \(error)")
        }
    }

    private static func url(_ name: String, _ ext: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "design") else {
            fatalError("design fixture \(name).\(ext) is missing from the SkillcaskUI bundle")
        }
        return url
    }
}
