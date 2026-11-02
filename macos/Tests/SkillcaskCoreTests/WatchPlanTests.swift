import Foundation
import Testing

@testable import SkillcaskCore

/// `WatchPlan`: which changes on disk live refresh acts on, and which directories it watches, over a real temporary
/// tree (its `/var/folders` path is a symlink, so every expectation goes through the canonical spelling FSEvents
/// reports).
@Suite struct WatchPlanTests {
    let base: URL
    let home: URL
    let project: URL
    let config: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "watch-plan-\(UUID().uuidString)")
        home = base.appending(path: "home")
        project = base.appending(path: "work/app")
        config = home.appending(path: ".config/skillcask")
        for dir in [project.appending(path: ".agents/skills"), project.appending(path: ".claude/skills"), config] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `relative` under `url`, spelled as FSEvents reports it.
    func reported(_ url: URL, _ relative: String = "") -> String {
        let path = WatchPlan.canonical(url.path)
        return relative.isEmpty ? path : (path as NSString).appendingPathComponent(relative)
    }

    func projectPlan(targets: [String] = [".claude/skills"], local: String? = nil) -> WatchPlan {
        WatchPlan(scope: .project(project), configDirectory: config, targetDirs: targets, local: local, home: home)
    }

    @Test func whatAProjectReadsIsRelevant() {
        let plan = projectPlan()
        for relative in [
            "skills.toml", "skills.lock", ".skills/foo/SKILL.md", ".skills", ".agents/skills/foo",
            ".agents/skills/foo/SKILL.md", ".agents", ".claude/skills/foo", ".claude",
        ] {
            #expect(plan.isRelevant(reported(project, relative)), "\(relative)")
        }
        #expect(plan.isRelevant(reported(config, "config.toml")))
        #expect(plan.isRelevant(reported(project, ".agents/skills/")))
    }

    @Test func theRestOfTheProjectIsNot() {
        let plan = projectPlan()
        for relative in [
            "", "README.md", "src/main.rs", "node_modules/x/SKILL.md", ".git/index", "src/.skills/foo/SKILL.md",
            ".claude/settings.json", ".agents/other", "skills.toml.bak",
        ] {
            #expect(!plan.isRelevant(reported(project, relative)), "\(relative)")
        }
        #expect(!plan.isRelevant(reported(config, "auth.json")))
        #expect(!plan.isRelevant(reported(config)))
        #expect(!plan.isRelevant(reported(home)))
        #expect(!plan.isRelevant("/"))
    }

    @Test func aProjectWatchesItsRootAndTheConfigDirectory() {
        #expect(projectPlan().roots == [reported(config), reported(project)].sorted())
    }

    @Test func aTargetOutsideTheProjectIsWatchedWhereItIs() throws {
        let shared = base.appending(path: "shared/skills")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let plan = projectPlan(targets: [".claude/skills", "../../shared/skills"])
        #expect(plan.isRelevant(reported(shared, "foo/SKILL.md")))
        #expect(plan.roots.contains(reported(shared)))
        let absolute = projectPlan(targets: [shared.path])
        #expect(absolute.isRelevant(reported(shared, "foo")))
        #expect(projectPlan(targets: ["~/.claude/skills"]).isRelevant(reported(home, ".claude/skills/foo")))
    }

    @Test func personalSkillsWatchTheirDirectoriesButNeverTheWholeHome() throws {
        try FileManager.default.createDirectory(
            at: home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        let plan = WatchPlan(scope: .personal, configDirectory: config, targetDirs: [".claude/skills"], home: home)
        // `~/.agents` does not exist: the store is not watched rather than the home folder.
        #expect(plan.roots == [reported(config), reported(home, ".claude/skills")].sorted())
        #expect(plan.isRelevant(reported(config, "skills.toml")))
        #expect(plan.isRelevant(reported(config, "skills.lock")))
        #expect(plan.isRelevant(reported(home, ".agents/skills/foo/SKILL.md")))
        #expect(plan.isRelevant(reported(home, ".claude/skills/foo")))
        #expect(!plan.isRelevant(reported(home, ".skills/foo/SKILL.md")))
        #expect(!plan.isRelevant(reported(home, "Documents/notes.md")))
        #expect(!plan.isRelevant(reported(home, ".config")))

        // `~/.agents` alone is not watched for the store either: it is picked up once it exists.
        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        let before = WatchPlan(scope: .personal, configDirectory: config, targetDirs: [".claude/skills"], home: home)
        #expect(!before.roots.contains(reported(home, ".agents")))
        try FileManager.default.createDirectory(
            at: home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        let later = WatchPlan(scope: .personal, configDirectory: config, targetDirs: [".claude/skills"], home: home)
        #expect(later.roots.contains(reported(home, ".agents/skills")))
    }

    @Test func aMissingPersonalTargetIsNotWatchedThroughItsBusyParent() throws {
        try FileManager.default.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let plan = WatchPlan(scope: .personal, configDirectory: config, targetDirs: [".claude/skills"], home: home)
        #expect(plan.roots == [reported(config)], "not ~/.claude, which Claude Code writes to all the time")
        #expect(plan.isRelevant(reported(home, ".claude/skills/foo")), "still relevant once it is watched")
    }

    @Test func aMissingTargetOutsideTheProjectWaitsUntilItExists() throws {
        try FileManager.default.createDirectory(at: base.appending(path: "shared"), withIntermediateDirectories: true)
        let plan = projectPlan(targets: ["../../shared/skills"])
        #expect(plan.roots == [reported(config), reported(project)].sorted())
    }

    @Test func theProjectSkillsDirectoryIsTheOneStatusReports() {
        let custom = projectPlan(local: "docs/skills")
        #expect(custom.isRelevant(reported(project, "docs/skills/foo/SKILL.md")))
        #expect(custom.isRelevant(reported(project, "docs")))
        #expect(!custom.isRelevant(reported(project, ".skills/foo/SKILL.md")))
        #expect(!custom.isRelevant(reported(project, "docs/guide.md")))
        // An older CLI prints no `local`: the default.
        for plan in [projectPlan(), projectPlan(local: "")] {
            #expect(plan.isRelevant(reported(project, ".skills/foo/SKILL.md")))
            #expect(!plan.isRelevant(reported(project, "docs/skills/foo/SKILL.md")))
        }
    }

    @Test func anEmptyPathIsNeverRelevantNorInsideAnything() {
        let plan = projectPlan()
        #expect(!plan.isRelevant(""))
        #expect(!plan.accepts("", rescan: false))
        #expect(!WatchPlan.isInside("", "/a"))
        #expect(!WatchPlan.isInside("/", ""))
    }

    @Test func aRescanIsAcceptedOnlyWhereItCanHideAChange() {
        let plan = projectPlan()
        for relative in [".venv/lib", ".next/cache", "Pods", ".gradle", "coverage", "src"] {
            #expect(!plan.accepts(reported(project, relative), rescan: true), "\(relative)")
        }
        for relative in ["", ".agents", ".agents/skills/foo", ".claude", "skills.lock"] {
            #expect(plan.accepts(reported(project, relative), rescan: true), "\(relative)")
        }
        #expect(plan.accepts("/", rescan: true))
        #expect(plan.accepts("", rescan: true), "a rescan with no path could be anywhere")
        #expect(!plan.accepts(reported(project), rescan: false), "the root itself is a boundary")
    }

    @Test func aTargetThatIsASymlinkIsAlsoMatchedByItsOwnName() throws {
        let elsewhere = base.appending(path: "elsewhere/skills")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appending(path: ".cursor-skills"), withDestinationURL: elsewhere)
        let plan = projectPlan(targets: [".cursor-skills"])
        #expect(plan.isRelevant(reported(elsewhere, "foo/SKILL.md")), "what the link points to")
        #expect(plan.isRelevant(reported(project, ".cursor-skills")), "the link itself, retargeted")
        #expect(plan.roots.contains(reported(elsewhere)) && !plan.roots.contains(reported(project, ".cursor-skills")))
    }

    @Test func aSymlinkedSpellingOfTheProjectMatchesTheReportedPath() throws {
        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
        let plan = WatchPlan(scope: .project(link), configDirectory: config, targetDirs: [], home: home)
        #expect(plan.isRelevant(reported(project, "skills.toml")))
        #expect(plan.roots.contains(reported(project)))
    }

    @Test func heavyDirectoriesUnderTheProjectAreExcludedUnlessTheyHoldALocation() throws {
        for name in [".git", "node_modules", "vendor/skills", "src"] {
            try FileManager.default.createDirectory(
                at: project.appending(path: name), withIntermediateDirectories: true)
        }
        let plan = projectPlan(targets: [".claude/skills", "vendor/skills"])
        #expect(plan.exclusions == [reported(project, ".git"), reported(project, "node_modules")])
        let personal = WatchPlan(scope: .personal, configDirectory: config, targetDirs: [], home: home)
        #expect(personal.exclusions.isEmpty)
    }

    @Test func aDeletedProjectIsNotWatchedThroughItsParent() throws {
        try FileManager.default.removeItem(at: project)
        let plan = projectPlan()
        #expect(plan.roots == [reported(config)])
        #expect(plan.exclusions.isEmpty)
    }

    @Test func outermostKeepsOnlyDirectoriesNotInsideAnother() {
        #expect(WatchPlan.outermost(["/a/b", "/a", "/ab", "/a/b/c", "/a"]) == ["/a", "/ab"])
    }

    @Test func canonicalResolvesTheExistingPrefixAndKeepsTheRest() {
        let missing = project.appending(path: "nope/deeper")
        #expect(WatchPlan.canonical(missing.path) == reported(project, "nope/deeper"))
        #expect(WatchPlan.canonical("/") == "/")
    }
}
