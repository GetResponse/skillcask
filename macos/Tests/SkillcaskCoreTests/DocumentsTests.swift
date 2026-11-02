import Foundation
import Testing

@testable import SkillcaskCore

@Suite struct StatusDocumentTests {
    @Test(arguments: Fixture.versions) func healthyProjectDecodes(version: String) throws {
        let doc = try Fixture.decode(StatusDocument.self, version, "status")
        #expect(doc.ok)
        #expect(doc.entries.map(\.state) == ["ok", "ok", "project"])
        #expect(doc.entries.map(\.package) == ["netresearch/agent-jira-skill", "netresearch/agent-jira-skill", nil])
        #expect(doc.entries.map(\.skill) == ["jira-communication", "jira-syntax", "notes"])
        #expect(doc.entries.allSatisfy { $0.via.isEmpty && $0.adopt == nil })
        #expect(doc.policy["allow-ranges"] == StatusDocument.Policy(value: .bool(true), from: "skills.toml"))
        #expect(doc.policy["min-release-age"]?.value.shown == "72h")
        #expect(doc.targets == StatusDocument.Targets(entries: ["claude"], dirs: [".claude/skills"], from: "default"))
        #expect(doc.repositories.map(\.name) == ["packagist", "github"])
        #expect(doc.repositories.allSatisfy { $0.allowed })
    }

    @Test func targetsLocalIsReadWhenPrintedAndNilFromAnOlderCLI() throws {
        let newer = try JSONDecoder()
            .decode(
                StatusDocument.Targets.self,
                from: Data(
                    #"{"entries":["claude"],"dirs":[".claude/skills"],"from":"default","local":"docs/skills"}"#.utf8))
        #expect(newer.local == "docs/skills")
        let global = try JSONDecoder()
            .decode(
                StatusDocument.Targets.self, from: Data(#"{"entries":[],"dirs":[],"from":"default","local":null}"#.utf8)
            )
        #expect(global.local == nil)
        let older = try JSONDecoder()
            .decode(
                StatusDocument.Targets.self, from: Data(#"{"entries":[],"dirs":[],"from":"default"}"#.utf8))
        #expect(older.local == nil)
    }

    @Test(arguments: Fixture.versions) func emptyProjectHasNoEntries(version: String) throws {
        let doc = try Fixture.decode(StatusDocument.self, version, "status.empty")
        #expect(doc.ok && doc.entries.isEmpty && doc.targets != nil)
    }

    @Test(arguments: Fixture.versions, ["status.problem", "status.missing"])
    func problemDocumentsStillDecode(version: String, name: String) throws {
        let doc = try Fixture.decode(StatusDocument.self, version, name)
        #expect(!doc.ok)
        let bad = doc.entries.filter { !$0.ok }
        #expect(bad.map(\.skill) == ["jira-syntax"])
        #expect(["modified", "not installed"].contains(bad[0].state))
    }

    @Test func dependencyCarriesItsRequirersInVia() throws {
        let synthetic = #"""
            {"entries":[{"adopt":null,"ok":true,"package":"acme/dep","skill":"d","state":"ok","version":"1.0.0","via":["acme/one","acme/two"],"description":"Does d.","added-later":1},{"adopt":null,"ok":false,"package":"acme/gone","skill":null,"state":"not in skills.lock","version":null,"via":null}],"ok":false}
            """#
        let doc = try JSONDecoder().decode(StatusDocument.self, from: Data(synthetic.utf8))
        #expect(doc.entries[0].package == "acme/dep" && doc.entries[0].description == "Does d.")
        #expect(doc.entries[0].via == ["acme/one", "acme/two"])
        #expect(doc.entries[1].package == "acme/gone" && doc.entries[1].via.isEmpty && doc.entries[1].skill == nil)
        #expect(doc.policy.isEmpty && doc.repositories.isEmpty && doc.targets == nil)
    }

    @Test func plannedSourceKeyIsOptional() throws {
        let synthetic = #"""
            {"entries":[{"ok":true,"package":"acme/one","skill":"a","state":"ok","version":"1.0.0","source":"packagist"},{"ok":true,"package":"acme/two","skill":"b","state":"ok","version":"1.0.0"}],"ok":true}
            """#
        let doc = try JSONDecoder().decode(StatusDocument.self, from: Data(synthetic.utf8))
        #expect(doc.entries.map(\.source) == ["packagist", nil])
    }

    @Test func notManagedEntryCarriesTheAdoptSource() throws {
        let synthetic = #"""
            {"entries":[{"adopt":"github:JuliusBrussee/caveman/cavecrew","ok":true,"package":null,"skill":"cavecrew","state":"not managed","version":null},{"adopt":null,"ok":true,"package":null,"skill":"mine","state":"not managed","version":null}],"ok":true}
            """#
        let doc = try JSONDecoder().decode(StatusDocument.self, from: Data(synthetic.utf8))
        #expect(doc.entries.map(\.adopt) == ["github:JuliusBrussee/caveman/cavecrew", nil])
    }
}

@Suite struct OutdatedDocumentTests {
    @Test(arguments: Fixture.versions) func lockedAtLatest(version: String) throws {
        let doc = try Fixture.decode(OutdatedDocument.self, version, "outdated")
        #expect(doc.behind.isEmpty)
        #expect(doc.packages.count == 1)
        #expect(
            doc.packages[0].locked == "v4.3.0" && doc.packages[0].within == "v4.3.0"
                && doc.packages[0].latest == "v4.3.0")
        #expect(doc.packages[0].note == nil && doc.packages[0].eligible == nil)
    }

    @Test(arguments: Fixture.versions) func emptyProject(version: String) throws {
        let doc = try Fixture.decode(OutdatedDocument.self, version, "outdated.empty")
        #expect(doc.packages.isEmpty && doc.behind.isEmpty)
    }

    @Test func cooldownNoteAndUnlockedPackage() throws {
        let synthetic = #"""
            {"behind":["netresearch/agent-jira-skill"],"packages":[{"latest":"v4.3.0","locked":"v4.2.0","note":"v4.3.0 eligible 2026-10-26T21:44:27Z","package":"netresearch/agent-jira-skill","within":"v4.3.0"},{"latest":null,"locked":null,"note":null,"package":"acme/new","within":null}]}
            """#
        let doc = try JSONDecoder().decode(OutdatedDocument.self, from: Data(synthetic.utf8))
        #expect(doc.behind == ["netresearch/agent-jira-skill"])
        #expect(doc.packages[0].note?.hasPrefix("v4.3.0 eligible ") == true)
        #expect(doc.packages[1].locked == nil && doc.packages[1].within == nil)
    }

    @Test func plannedReleasedKeyIsOptional() throws {
        let synthetic = #"""
            {"behind":[],"packages":[{"latest":"1.4.0","locked":"1.2.0","note":null,"package":"acme/one","within":"1.4.0","released":"2026-10-24T00:00:00Z"},{"latest":"1.0.0","locked":"1.0.0","note":null,"package":"acme/two","within":"1.0.0"}]}
            """#
        let doc = try JSONDecoder().decode(OutdatedDocument.self, from: Data(synthetic.utf8))
        #expect(doc.packages.map(\.released) == ["2026-10-24T00:00:00Z", nil])
    }
}

@Suite struct InfoDocumentTests {
    @Test(arguments: Fixture.versions) func packageShape(version: String) throws {
        let doc = try Fixture.decode(InfoDocument.self, version, "info.package")
        #expect(doc.package == "netresearch/agent-jira-skill")
        #expect(doc.source == "composer" && doc.repository == "https://repo.packagist.org/")
        #expect(doc.locked == true && doc.version == "v4.3.0")
        #expect(doc.abandoned == .replacedBy("netresearch/jira-skill"))
        #expect(doc.skills.map(\.name) == ["jira-communication", "jira-syntax"])
        #expect(doc.versions.first == "v4.3.0" && doc.requires.isEmpty)
        #expect(doc.why == [#"netresearch/agent-jira-skill: in skills.toml as "^4.3""#])
        #expect(doc.kind == nil && doc.skill == nil)
    }

    @Test(arguments: Fixture.versions) func skillOfAPackage(version: String) throws {
        let doc = try Fixture.decode(InfoDocument.self, version, "info.skill.package")
        #expect(doc.kind == "package" && doc.skill == "jira-syntax")
        #expect(doc.package == "netresearch/agent-jira-skill" && doc.version == "v4.3.0")
        #expect(doc.path == ".agents/skills/jira-syntax" && doc.from == nil)
        #expect(doc.why.count == 1 && doc.skills.isEmpty)
    }

    @Test(arguments: Fixture.versions) func projectSkill(version: String) throws {
        let doc = try Fixture.decode(InfoDocument.self, version, "info.skill.project")
        #expect(doc.kind == "project" && doc.skill == "notes" && doc.path == ".skills/notes")
        #expect(doc.package == nil && doc.version == nil && doc.description == nil)
    }

    @Test(arguments: [
        (#"{"package":"a/b","abandoned":true}"#, InfoDocument.Abandoned?.some(.withoutReplacement)),
        (#"{"package":"a/b","abandoned":"a/c"}"#, .some(.replacedBy("a/c"))),
        (#"{"package":"a/b","abandoned":false}"#, nil),
        (#"{"package":"a/b","abandoned":null}"#, nil),
        (#"{"package":"a/b"}"#, nil),
    ])
    func abandoned(json: String, expected: InfoDocument.Abandoned?) throws {
        let doc = try JSONDecoder().decode(InfoDocument.self, from: Data(json.utf8))
        #expect(doc.abandoned == expected)
    }
}

@Suite struct SearchDocumentTests {
    @Test(arguments: Fixture.versions) func undecidedSkillsSh(version: String) throws {
        let doc = try Fixture.decode(SearchDocument.self, version, "search")
        #expect(doc.skillsSh == .undecided)
        #expect(doc.results.count == 3)
        #expect(doc.results.allSatisfy { $0.source == "packagist" && $0.installs == nil })
        #expect(doc.results[0].name == "netresearch/jira-skill")
    }

    @Test(arguments: [
        (#"{"results":[],"skills-sh":true}"#, SearchDocument.SkillsSh.enabled),
        (#"{"results":[],"skills-sh":false}"#, .disabled),
        (#"{"results":[],"skills-sh":null}"#, .undecided),
        (#"{"results":[]}"#, .unknown),
    ])
    func skillsShStates(json: String, expected: SearchDocument.SkillsSh) throws {
        #expect(try JSONDecoder().decode(SearchDocument.self, from: Data(json.utf8)).skillsSh == expected)
    }

    @Test func skillsShResultCarriesInstalls() throws {
        let synthetic = #"""
            {"results":[{"description":null,"installs":594431,"name":"github:juliusbrussee/caveman/caveman","source":"skills.sh"}],"skills-sh":true}
            """#
        let doc = try JSONDecoder().decode(SearchDocument.self, from: Data(synthetic.utf8))
        #expect(
            doc.results[0].installs == 594_431 && doc.results[0].source == "skills.sh"
                && doc.results[0].description == nil)
    }
}

@Suite struct DoctorDocumentTests {
    @Test(arguments: Fixture.versions) func healthy(version: String) throws {
        let doc = try Fixture.decode(DoctorDocument.self, version, "doctor.empty")
        #expect(doc.ok && doc.problems.isEmpty && doc.fixed.isEmpty && doc.warnings.isEmpty)
        #expect(doc.passed.count == 5 && doc.passed.first == "links: 0 ok")
    }

    @Test(arguments: Fixture.versions) func problems(version: String) throws {
        let doc = try Fixture.decode(DoctorDocument.self, version, "doctor.problem")
        #expect(!doc.ok && doc.problems.count == 2)
        #expect(doc.problems[0] == ".claude/skills/jira-syntax: link wrong")
    }
}

@Suite struct AuditDocumentTests {
    @Test(arguments: Fixture.versions) func riskyProjectSkillHasFindings(version: String) throws {
        let doc = try Fixture.decode(AuditDocument.self, version, "audit")
        #expect(!doc.ok)
        #expect(doc.skills.map(\.skill) == ["jira-communication", "jira-syntax", "notes"])
        #expect(doc.skills.map(\.kind) == ["package", "package", "project"])
        #expect(doc.skills[0].package == "netresearch/agent-jira-skill" && doc.skills[0].version == "v4.3.0")
        let notes = doc.skills[2]
        #expect(notes.package == nil && notes.path == ".skills/notes")
        #expect(!notes.findings.isEmpty && notes.findings.allSatisfy { $0.rule == "risky-pattern" })
        #expect(
            notes.network.contains("x.example") && notes.paths.contains("~/.ssh/id_rsa") && notes.env.contains("HOME"))
    }

    @Test(arguments: Fixture.versions) func modifiedSkillIsAFinding(version: String) throws {
        let doc = try Fixture.decode(AuditDocument.self, version, "audit.problem")
        let modified = doc.skills.flatMap(\.findings).filter { $0.rule == "modified" }
        #expect(modified.count == 1 && modified[0].line == nil && modified[0].path == ".agents/skills/jira-syntax")
    }

    @Test(arguments: Fixture.versions) func emptyProject(version: String) throws {
        let doc = try Fixture.decode(AuditDocument.self, version, "audit.empty")
        #expect(doc.ok && doc.skills.isEmpty)
    }
}

@Suite struct ProjectsDocumentTests {
    @Test(arguments: Fixture.versions) func paths(version: String) throws {
        let doc = try Fixture.decode(ProjectsDocument.self, version, "projects")
        #expect(doc.projects.count == 1 && doc.projects[0].path.hasSuffix("demo_fixtures"))
    }
}

@Suite struct MutationDocumentTests {
    @Test func everyKeyIsOptional() throws {
        let full =
            #"{"ok":true,"added":["a/b"],"installed":["x"],"updated":["a/b v1 -> v2"],"removed":[],"warnings":["w"]}"#
        let doc = try JSONDecoder().decode(MutationDocument.self, from: Data(full.utf8))
        #expect(
            doc.ok && doc.added == ["a/b"] && doc.installed == ["x"] && doc.updated.count == 1 && doc.warnings == ["w"])
        let bare = try JSONDecoder().decode(MutationDocument.self, from: Data("{}".utf8))
        #expect(bare.ok && bare.added.isEmpty && bare.removed.isEmpty)
    }
}

@Suite struct JSONValueTests {
    @Test func decodesEveryShapeAndShowsItLikeTheCLI() throws {
        let json = #"{"a":true,"b":"72h","c":["packagist","github"],"d":null,"e":3,"f":1.5,"g":{"k":false}}"#
        let value = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
        #expect(value["a"] == .bool(true) && value["b"] == .string("72h"))
        #expect(value["c"]?.shown == "packagist, github")
        #expect(value["d"] == .null && value["d"]?.shown == "none")
        #expect(value["e"]?.shown == "3" && value["f"]?.shown == "1.5")
        #expect(value["g"]?.shown == "k=false")
    }
}
