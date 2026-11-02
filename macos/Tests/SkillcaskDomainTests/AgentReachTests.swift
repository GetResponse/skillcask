import Foundation
import SkillcaskCore
import Testing

@testable import SkillcaskDomain

/// `AgentTarget.resolve` and `AgentIndex`: which agents see a skill, from `status` and `doctor` alone.
@Suite struct AgentReachTests {
    /// One status entry as JSON: a package skill by default.
    static func row(_ skill: String, package: String? = "acme/x", state: String = "ok") -> String {
        let package = package.map { "\"\($0)\"" } ?? "null"
        return #"{"package":\#(package),"version":"1.0.0","skill":"\#(skill)","state":"\#(state)","ok":true}"#
    }

    static func snapshot(
        entries: [String], targets: [String], dirs: [String], doctor problems: [String]?
    ) throws -> ScopeSnapshot {
        let quoted = { (items: [String]) in items.map { "\"\($0)\"" }.joined(separator: ",") }
        let status = #"""
            {"ok":true,"entries":[\#(entries.joined(separator: ","))],"policy":{},
            "targets":{"entries":[\#(quoted(targets))],"dirs":[\#(quoted(dirs))],"from":"skills.toml"}}
            """#
        let doctor = problems.map {
            #"{"ok":false,"passed":[],"problems":[\#(quoted($0))],"fixed":[],"warnings":[]}"#
        }
        return try ScopeSnapshot(
            status: JSONDecoder().decode(StatusDocument.self, from: Data(status.utf8)), audit: nil,
            doctor: doctor.map { try JSONDecoder().decode(DoctorDocument.self, from: Data($0.utf8)) },
            outdated: nil)
    }

    /// The states of `skill`'s links by target entry.
    static func states(
        _ skill: String, entries: [String]? = nil, targets: [String] = ["claude", "cursor"],
        dirs: [String] = [".claude/skills"], doctor: [String]? = [], isGlobal: Bool = false,
        check: AgentIndex.LinkCheck? = nil
    ) throws -> [String: AgentReach.State] {
        let snapshot = try snapshot(entries: entries ?? [row(skill)], targets: targets, dirs: dirs, doctor: doctor)
        let entry = try #require(snapshot.entry(id: skill))
        let reach = AgentIndex(snapshot: snapshot, isGlobal: isGlobal, check: check).reach(of: entry)
        return Dictionary(uniqueKeysWithValues: reach.links.map { ($0.target.entry, $0.state) })
    }

    // MARK: - Targets

    static func targets(_ entries: [String], _ dirs: [String], isGlobal: Bool = false) throws -> [AgentTarget] {
        let quoted = { (items: [String]) in items.map { "\"\($0)\"" }.joined(separator: ",") }
        let json = #"{"entries":[\#(quoted(entries))],"dirs":[\#(quoted(dirs))],"from":"skills.toml"}"#
        return AgentTarget.resolve(
            try JSONDecoder().decode(StatusDocument.Targets.self, from: Data(json.utf8)), isGlobal: isGlobal)
    }

    @Test func targetsPairEntriesWithTheirDirectoriesNotByIndex() throws {
        let resolved = try Self.targets(
            ["cursor", "claude", "./tools/skills/", "kiro"], [".claude/skills", "tools/skills", ".kiro/skills"])
        #expect(resolved.map(\.directory) == [nil, ".claude/skills", "tools/skills", ".kiro/skills"])
        #expect(resolved.map(\.readsFrom) == [".agents/skills", ".claude/skills", "tools/skills", ".kiro/skills"])
        #expect(resolved[2].isPath && !resolved[0].isPath)
        #expect(AgentTarget.resolve(nil, isGlobal: false).isEmpty)
    }

    @Test func onlyPresetsWithTheirOwnDirectoryGetOne() throws {
        // `cursor` reads the store even when a path target names `.cursor/skills`.
        let cursor = try Self.targets(["cursor", "./.cursor/skills"], [".cursor/skills"])
        #expect(cursor.map(\.directory) == [nil, ".cursor/skills"])
        // `junie` links only in the global scope.
        #expect(try Self.targets(["junie"], []).map(\.directory) == [nil])
        let global = try Self.targets(["junie", "claude"], [".junie/skills", ".claude/skills"], isGlobal: true)
        #expect(global.map(\.directory) == [".junie/skills", ".claude/skills"])
        #expect(global.map(\.shownPath) == ["~/.junie/skills", "~/.claude/skills"])
        #expect(try Self.targets(["codex"], []).map(\.shownPath) == [".agents/skills"])
    }

    @Test func claudeCodeAndCodexComeFirstThenPresetsThenPaths() throws {
        let order = { (entries: [String]) in
            AgentTarget.displayOrder(entries.map { AgentTarget(entry: $0, directory: nil) }).map(\.entry)
        }
        #expect(
            order(["kiro", "./tools/skills", "codex", "cursor", "claude"]) == [
                "claude", "codex", "kiro", "cursor", "./tools/skills",
            ])
        #expect(order(["codex", "kiro", "claude"]) == ["claude", "codex", "kiro"])
        #expect(order(["claude", "kiro", "codex", "./tools/skills"]) == ["claude", "codex", "kiro", "./tools/skills"])
        #expect(order(["cursor", "./a/skills", "kiro"]) == ["cursor", "kiro", "./a/skills"], "no priority agent")
        // The index keeps the config order for the Agents card and lists each reach in display order.
        let snapshot = try Self.snapshot(
            entries: [Self.row("pdf")], targets: ["kiro", "codex", "claude"], dirs: [".kiro/skills", ".claude/skills"],
            doctor: [])
        let index = AgentIndex(snapshot: snapshot, isGlobal: false)
        #expect(index.targets.map(\.entry) == ["kiro", "codex", "claude"])
        let pdf = try #require(snapshot.entry(id: "pdf"))
        #expect(index.reach(of: pdf).links.map(\.target.entry) == ["claude", "codex", "kiro"])
    }

    @Test func aRepeatedEntryIsOneTarget() throws {
        let resolved = try Self.targets(["claude", "kiro", "claude"], [".claude/skills", ".kiro/skills"])
        #expect(resolved.map(\.entry) == ["claude", "kiro"])
        #expect(Set(resolved.map(\.id)).count == resolved.count)
    }

    // MARK: - Reach

    @Test func everyTargetLinkedWhenDoctorReportsNothing() throws {
        #expect(try Self.states("pdf") == ["claude": .linked, "cursor": .linked])
    }

    @Test func oneTargetMissingIsThatAgentsProblemOnly() throws {
        let states = try Self.states(
            "pdf", targets: ["claude", "kiro"], dirs: [".claude/skills", ".kiro/skills"],
            doctor: [".kiro/skills/pdf: link missing", ".kiro/skills/pdf-tools: link missing"])
        #expect(states == ["claude": .linked, "kiro": .missing])
    }

    @Test func brokenLinkInOneTargetIsWrongAndAForeignFileIsBlocked() throws {
        #expect(
            try Self.states("pdf", doctor: [".claude/skills/pdf: link wrong"]) == ["claude": .wrong, "cursor": .linked])
        #expect(
            try Self.states("pdf", doctor: [".claude/skills/pdf exists and was not created by skillcask; move it away"])
                == ["claude": .blocked, "cursor": .linked])
        #expect(
            try Self.states("pdf", doctor: [".claude/skills/pdf: link foreign"]) == [
                "claude": .blocked, "cursor": .linked,
            ])
    }

    @Test func tildePathsMatchOnlyInTheGlobalScope() throws {
        let line = ["~/.claude/skills/pdf: link missing"]
        #expect(try Self.states("pdf", doctor: line, isGlobal: true) == ["claude": .missing, "cursor": .linked])
        #expect(try Self.states("pdf", doctor: line, isGlobal: false) == ["claude": .linked, "cursor": .linked])
        #expect(DoctorItem.scopeRelative("~/.claude/skills/x", isGlobal: false) == "~/.claude/skills/x")
    }

    @Test func notInstalledReachesNoAgentAndDrawsNoRowBadges() throws {
        let byStatus = try Self.states("jira", entries: [Self.row("jira", state: "not installed")])
        #expect(byStatus == ["claude": .notInstalled, "cursor": .notInstalled])
        let byDoctor = try Self.states(
            "jira",
            doctor: [
                ".claude/skills/jira: link missing",
                ".agents/skills/jira: not installed (acme/x); run `skillcask install`",
            ])
        #expect(byDoctor == ["claude": .notInstalled, "cursor": .notInstalled])
        let reach = AgentReach(links: [
            AgentReach.Link(target: AgentTarget(entry: "claude", directory: nil), state: .notInstalled)
        ])
        #expect(!reach.showsOnRow)
    }

    @Test func aBrokenStoreLinkIsTheCauseForEveryAgent() throws {
        // What the 0.10.2 CLI prints when a project skill's store link is gone: the store line and `link wrong` in
        // every target directory, whose links now dangle.
        let states = try Self.states(
            "notes", entries: [Self.row("notes", package: nil, state: "not linked")],
            targets: ["claude", "kiro", "codex"], dirs: [".claude/skills", ".kiro/skills"],
            doctor: [
                ".agents/skills/notes: link missing", ".claude/skills/notes: link wrong",
                ".kiro/skills/notes: link wrong",
            ])
        #expect(states == ["claude": .storeLinkBroken, "kiro": .storeLinkBroken, "codex": .storeLinkBroken])
    }

    @Test func aForeignFolderAtTheStorePathBlocksEveryAgentAndIsNoRepair() throws {
        // What the 0.10.2 CLI prints with a folder skillcask did not create at `.agents/skills/notes`: `doctor --fix`
        // never touches it, so it is not the broken store link Repair relinks.
        let states = try Self.states(
            "notes", entries: [Self.row("notes", package: nil, state: "not linked")],
            targets: ["claude", "codex"], dirs: [".claude/skills"],
            doctor: [".agents/skills/notes: link foreign", ".claude/skills/notes: link wrong"])
        #expect(states == ["claude": .storeBlocked, "codex": .storeBlocked])
        let notOurs = try Self.states(
            "notes", entries: [Self.row("notes", package: nil, state: "not linked")],
            doctor: [".agents/skills/notes exists and was not created by skillcask; move it away"])
        #expect(notOurs == ["claude": .storeBlocked, "cursor": .storeBlocked])
        #expect(AgentReach.State.storeBlocked.isProblem && AgentReach.State.storeBlocked.isStoreProblem)
    }

    @Test func aStoreAgentSeesAnInstalledSkillWhateverTheOtherLinks() throws {
        let states = try Self.states(
            "pdf", targets: ["claude", "codex"], dirs: [".claude/skills"], doctor: [".claude/skills/pdf: link missing"])
        #expect(states == ["claude": .missing, "codex": .linked])
    }

    @Test func singleTargetShowsABadgeOnlyWhenItsLinkIsBroken() throws {
        let healthy = try Self.snapshot(
            entries: [Self.row("pdf")], targets: ["claude"], dirs: [".claude/skills"], doctor: [])
        let pdf = try #require(healthy.entry(id: "pdf"))
        #expect(!AgentIndex(snapshot: healthy, isGlobal: false).reach(of: pdf).showsOnRow)
        let broken = try Self.snapshot(
            entries: [Self.row("pdf")], targets: ["claude"], dirs: [".claude/skills"],
            doctor: [".claude/skills/pdf: link missing"])
        #expect(AgentIndex(snapshot: broken, isGlobal: false).reach(of: pdf).showsOnRow)
    }

    @Test func noTargetsMakeNoClaim() throws {
        #expect(try Self.states("pdf", targets: [], dirs: []).isEmpty)
    }

    @Test func notManagedAndPackageOnlyRowsMakeNoClaim() throws {
        let snapshot = try Self.snapshot(
            entries: [
                Self.row("caveman", package: nil, state: "not managed"),
                #"{"package":"acme/gone","version":"1.0.0","skill":null,"state":"not in skills.toml","ok":false}"#,
            ], targets: ["claude", "cursor"], dirs: [".claude/skills"], doctor: [])
        let index = AgentIndex(snapshot: snapshot, isGlobal: false)
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries.allSatisfy { index.reach(of: $0).links.isEmpty })
    }

    @Test func handWrittenProjectAndDependencySkillsAreLinkedLikePackages() throws {
        let rows = [
            Self.row("mine", package: nil, state: "hand-written"), Self.row("notes", package: nil, state: "project"),
            #"{"package":"a/dep","version":"1.0.0","skill":"dep","state":"ok","ok":true,"via":["a/b"]}"#,
        ]
        for name in ["mine", "notes", "dep"] {
            let states = try Self.states(name, entries: rows, doctor: [".claude/skills/\(name): link wrong"])
            #expect(states == ["claude": .wrong, "cursor": .linked], "\(name)")
        }
    }

    @Test func linksAreNotClaimedBeforeOrWithoutACurrentDoctor() throws {
        #expect(try Self.states("pdf", doctor: nil) == ["claude": .pending, "cursor": .pending])
        // `doctor` failed this refresh: even with an older answer kept for Health, nothing is claimed linked.
        let failed = try Self.states("pdf", doctor: [".claude/skills/other: link missing"], check: .failed)
        #expect(failed == ["claude": .unknown, "cursor": .unknown])
        // The skill's own state from `status` stays known.
        let notInstalled = try Self.states(
            "jira", entries: [Self.row("jira", state: "not installed")], doctor: nil, check: .failed)
        #expect(notInstalled == ["claude": .notInstalled, "cursor": .notInstalled])
    }
}
