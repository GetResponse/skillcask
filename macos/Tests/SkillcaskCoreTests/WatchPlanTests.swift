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

    func projectPlan(targets: [String] = [".claude/skills"]) -> WatchPlan {
        WatchPlan(scope: .project(project), configDirectory: config, targetDirs: targets, home: home)
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

        try FileManager.default.createDirectory(at: home.appending(path: ".agents"), withIntermediateDirectories: true)
        let later = WatchPlan(scope: .personal, configDirectory: config, targetDirs: [".claude/skills"], home: home)
        #expect(later.roots.contains(reported(home, ".agents")))
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
