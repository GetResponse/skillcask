import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskDomain

@Suite struct MutationReportTests {
    @Test func verbLinesOfAnAdd() {
        let stdout = """
            added netresearch/agent-jira-skill = "^4.3" (v4.3.0)
            installed jira-communication (netresearch/agent-jira-skill v4.3.0)
            installed jira-syntax (netresearch/agent-jira-skill v4.3.0)

            """
        let report = MutationReport(verbLines: stdout, warnings: ["abandoned"])
        #expect(report.added == ["netresearch/agent-jira-skill"])
        #expect(report.installed == ["jira-communication", "jira-syntax"])
        #expect(report.warnings == ["abandoned"] && !report.isEmpty)
        #expect(report.addedVersions == ["netresearch/agent-jira-skill": "v4.3.0"])
    }

    /// `finish_add` prints `added <pkg> = {constraint:?} ({version})`; `adopt` prints `adopted <shown rel> (moved to
    /// <dest>)` for each folder it moved (src/commands.rs 1542, 1021).
    @Test func addedVersionAndAdoptedSkillsOfAnAdopt() {
        let stdout = """
            adopted ~/.claude/skills/caveman (moved to /Users/me/.config/skillcask/adopted/1761700000/.claude/skills/caveman)
            adopted ~/.agents/skills/caveman (moved to /Users/me/.config/skillcask/adopted/1761700000/.agents/skills/caveman)
            added juliusbrussee/caveman = "^4.0" (4.0.1)
            added acme/dep 2.0.0 (dependency of juliusbrussee/caveman)
            installed caveman (juliusbrussee/caveman 4.0.1)
            """
        let report = MutationReport(verbLines: stdout)
        #expect(report.addedVersions == ["juliusbrussee/caveman": "4.0.1"], "a dependency's line has no constraint")
        #expect(report.adoptedSkills == ["caveman"])
        // A GitHub or git ref locks a commit and prints its first 12 hex digits (src/github.rs 278).
        #expect(
            MutationReport(verbLines: "added a/b = \"main\" (3f2a9c1d0b7e)").addedVersions == ["a/b": "3f2a9c1d0b7e"])
        #expect(MutationReport(verbLines: "added a/b = \"*\" (1.0 beta)").addedVersions.isEmpty)
    }

    @Test func verbLinesOfUpdateRemoveAdoptAndInit() {
        let stdout = """
            updated acme/one 1.0.0 -> 1.1.0
            locked acme/dep 2.0.0
            added acme/dep 2.0.0 (dependency of acme/one)
            removed acme/old
            kept acme/dep as a dependency (required by acme/one)
            adopted .agents/skills/z (moved to ~/.config/skillcask/adopted/1)
            created skills.toml
            noise line
            """
        let report = MutationReport(verbLines: stdout)
        #expect(report.updated == [MutationReport.Updated(package: "acme/one", from: "1.0.0", to: "1.1.0")])
        #expect(report.locked == ["acme/dep"] && report.added == ["acme/dep"] && report.removed == ["acme/old"])
        #expect(
            report.kept == ["acme/dep"] && report.adopted == [".agents/skills/z"] && report.created == ["skills.toml"])
    }

    @Test func emptyOutputIsAnEmptyReport() {
        let report = MutationReport(verbLines: "")
        #expect(report.isEmpty && report.warnings.isEmpty)
    }

    @Test func fromTheDocument() throws {
        let json =
            #"{"ok":true,"added":["a/b"],"installed":["x"],"updated":["a/b 1 -> 2","garbage"],"removed":["c/d"],"warnings":["w"]}"#
        let document = try JSONDecoder().decode(MutationDocument.self, from: Data(json.utf8))
        let report = MutationReport(document, warnings: ["stderr"])
        #expect(report.added == ["a/b"] && report.installed == ["x"] && report.removed == ["c/d"])
        #expect(report.updated == [MutationReport.Updated(package: "a/b", from: "1", to: "2")])
        #expect(report.warnings == ["w", "stderr"])
    }
}

@Suite struct UnifiedDiffTests {
    @Test func packagesFilesAndHunks() {
        let text = """
            acme/one 1.0.0 -> 1.1.0
            --- a/one/SKILL.md
            +++ b/one/SKILL.md
            @@ -1,2 +1,2 @@
             # One
            -old
            +new
            --- /dev/null
            +++ b/one/scripts/run.sh
            new mode 100755
            @@ -0,0 +1 @@
            +echo hi
            --- a/one/gone.md
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            --- a/one/logo.png
            +++ b/one/logo.png
            Binary files differ
            --- a/one/big.txt
            +++ b/one/big.txt
            Files differ (too large to show)
            --- a/one/tool
            +++ b/one/tool
            old mode 100644
            new mode 100755
            acme/two 2.0.0 (new)
            --- /dev/null
            +++ b/two/SKILL.md
            @@ -0,0 +1 @@
            +# Two

            """
        let diff = UnifiedDiff(text: text)
        #expect(!diff.upToDate && diff.packages.map(\.name) == ["acme/one", "acme/two"])
        let one = diff.packages[0]
        #expect(one.from == "1.0.0" && one.to == "1.1.0")
        #expect(
            one.files.map(\.path) == [
                "one/SKILL.md", "one/scripts/run.sh", "one/gone.md", "one/logo.png", "one/big.txt", "one/tool",
            ])
        #expect(one.files.map(\.change) == [.modified, .added, .removed, .binary, .tooLarge, .modeOnly])
        #expect(one.files[0].lines == ["@@ -1,2 +1,2 @@", " # One", "-old", "+new"])
        #expect(one.files[1].lines == ["@@ -0,0 +1 @@", "+echo hi"])
        let two = diff.packages[1]
        #expect(two.from == nil && two.to == "2.0.0" && two.files.map(\.change) == [.added])
    }

    @Test func upToDateAndWarningsOnly() {
        let diff = UnifiedDiff(text: "warning: acme/one is abandoned\nno newer versions within the constraints\n")
        #expect(diff.upToDate && diff.packages.isEmpty)
        #expect(!UnifiedDiff(text: "").upToDate)
    }

    @Test func titles() {
        #expect(UnifiedDiff.title("acme/one 1.0.0 -> 1.1.0")! == ("acme/one", "1.0.0", "1.1.0"))
        #expect(UnifiedDiff.title("acme/one 1.1.0 (new)")! == ("acme/one", nil, "1.1.0"))
        #expect(UnifiedDiff.title("no newer versions within the constraints") == nil)
        #expect(UnifiedDiff.title("+++ b/x") == nil)
    }
}
