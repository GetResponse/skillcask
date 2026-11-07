import Foundation
import Testing

@testable import SkillcaskCore

@Suite struct ExitCodeTests {
    @Test(arguments: [
        (Int32(1), ExitCode.problem), (2, .signIn), (3, .network), (4, .integrity), (5, .file), (101, .other(101)),
        (0, .other(0)),
    ])
    func maps(status: Int32, expected: ExitCode) {
        #expect(ExitCode(status) == expected)
        #expect(ExitCode(status).status == status)
    }
}

@Suite struct StderrReportTests {
    @Test(arguments: Fixture.versions) func errorAndHintOutsideAProject(version: String) throws {
        let report = StderrReport(parsing: try Fixture.text(version, "status.noproject.stderr"))
        #expect(report.error == "skills.toml not found")
        #expect(report.hint == "run skillcask init")
        #expect(report.warnings.isEmpty && report.notes.isEmpty && report.other.isEmpty)
    }

    @Test func warningsNotesAndProgressLines() {
        let stderr = """
            warning: netresearch/agent-jira-skill is abandoned; use netresearch/jira-skill instead
            note: 2 packages checked
            fetching https://repo.packagist.org/p2/acme/one.json
            error: 1 finding(s)
            error: second error stays visible

            """
        let report = StderrReport(parsing: stderr)
        #expect(report.warnings == ["netresearch/agent-jira-skill is abandoned; use netresearch/jira-skill instead"])
        #expect(report.notes == ["2 packages checked"])
        #expect(report.error == "1 finding(s)" && report.hint == nil)
        #expect(
            report.other == [
                "fetching https://repo.packagist.org/p2/acme/one.json", "error: second error stays visible",
            ])
    }

    @Test func emptyAndColouredInput() {
        #expect(StderrReport(parsing: "") == StderrReport())
        let coloured = "\u{1B}[31merror\u{1B}[0m: boom\n  \u{1B}[36mhint\u{1B}[0m: try again\n"
        let report = StderrReport(parsing: coloured)
        #expect(report.error == "boom" && report.hint == "try again")
    }

    /// Regression: a message with its own line breaks (`src/deps.rs` conflicts) was cut to its first line.
    @Test func indentedLinesContinueTheError() {
        let stderr = "error: acme/x: no version fits:\n  acme/a (^1.0)\n  acme/b (^2.0)\n  hint: run update\n  stray\n"
        let report = StderrReport(parsing: stderr)
        #expect(report.error == "acme/x: no version fits:\nacme/a (^1.0)\nacme/b (^2.0)")
        #expect(report.hint == "run update" && report.other == ["  stray"])
    }
}

@Suite struct VersionTests {
    @Test(arguments: [
        ("0.9.1", Version(0, 9, 1)),
        ("v0.9.1", Version(0, 9, 1)),
        ("0.10.0-rc1", Version(0, 10, 0, prerelease: "rc1")),
        ("12.0.3", Version(12, 0, 3)),
    ])
    func parses(text: String, expected: Version) {
        #expect(Version(text) == expected)
        #expect(Version(expected.description) == expected)
    }

    @Test(arguments: ["", "0.9", "0.9.1.2", "a.b.c", "0.9.-1", "0.9.1-", "0.9.1 (sha)"])
    func rejects(text: String) {
        #expect(Version(text) == nil)
    }

    @Test func cliOutput() {
        #expect(Version(cliOutput: "skillcask 0.9.1 (1afcd7c81d2e)\n") == Version(0, 9, 1))
        #expect(Version(cliOutput: "skillcask 0.10.0-rc1 (unknown)") == Version(0, 10, 0, prerelease: "rc1"))
        #expect(Version(cliOutput: "error: unexpected argument") == nil)
        #expect(Version(cliOutput: "skillcask") == nil)
        #expect(Version(cliOutput: "cargo 1.80.0") == nil)
    }

    @Test func ordersNumericallyWithPrereleaseFirst() {
        let ordered = [
            Version(0, 9, 1), Version(0, 10, 0, prerelease: "rc1"), Version(0, 10, 0), Version(0, 10, 1),
            Version(1, 0, 0),
        ]
        #expect(ordered == ordered.shuffled().sorted())
        #expect(Version(0, 10, 0, prerelease: "rc1") < Version(0, 10, 0))
        #expect(Version(0, 10, 0, prerelease: "beta") < Version(0, 10, 0, prerelease: "rc1"))
        #expect(!(Version(0, 9, 1) < Version(0, 9, 1)))
    }

    /// SemVer 2.0 §11: dot-separated identifiers, numeric ones numerically and before alphanumeric ones, a longer
    /// set wins when the shared prefix is equal, the release after all its pre-releases.
    @Test func ordersPrereleaseBySemverPrecedence() throws {
        let texts = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
            "1.0.0-rc.1", "1.0.0",
        ]
        let ordered = try texts.map { try #require(Version($0)) }
        #expect(ordered == ordered.shuffled().sorted())
        for (lower, higher) in zip(ordered, ordered.dropFirst()) {
            #expect(lower < higher && !(higher < lower))
        }
        #expect(try #require(Version("0.10.1-rc.9")) < #require(Version("0.10.1-rc.10")))
        #expect(try #require(Version("0.10.1-rc.10")) < #require(Version("0.10.1")))
        // `rc10` is one alphanumeric identifier, so ASCII order applies: the CLI tags `rc.N`.
        #expect(Version(0, 10, 0, prerelease: "rc10") < Version(0, 10, 0, prerelease: "rc2"))
    }

    @Test func equalPrereleasesAreNeitherLess() {
        let version = Version(0, 10, 1, prerelease: "rc.10")
        #expect(version == Version(0, 10, 1, prerelease: "rc.10"))
        #expect(!(version < Version(0, 10, 1, prerelease: "rc.10")))
        #expect(!(Version(0, 10, 1) < Version(0, 10, 1)))
        // A leading zero is not a SemVer number; ordering it apart keeps `<` consistent with `==`.
        let padded = Version(0, 10, 1, prerelease: "rc.01")
        #expect(padded != version && (padded < version) != (version < padded))
    }
}

@Suite struct CapabilitiesTests {
    @Test func minimumVersionHasNoPlannedFeature() {
        let caps = Capabilities(version: Capabilities.minimum)
        #expect(caps.features.isEmpty && !caps.isTooOld)
        for feature in Capabilities.Feature.allCases {
            #expect(!caps.supports(feature))
        }
    }

    @Test func olderIsTooOldAndNewerIsNot() {
        #expect(Capabilities(version: Version(0, 9, 3)).isTooOld)
        #expect(Capabilities(version: Version(0, 9, 4, prerelease: "rc1")).isTooOld)
        #expect(!Capabilities(version: Version(0, 9, 4)).isTooOld)
        #expect(!Capabilities(version: Version(0, 10, 0)).isTooOld)
        #expect(!Capabilities(version: Version(0, 10, 1, prerelease: "rc.10")).isTooOld)
    }

    /// A shipped feature (`selfCheck`, 0.10.2) is on from that release and off before it and for every
    /// pre-release of it.
    @Test func shippedFeatureGateFollowsPrecedence() {
        func on(_ version: Version) -> Bool { Capabilities(version: version).features == [.selfCheck] }
        #expect(on(Version(0, 10, 2)) && on(Version(0, 10, 3)) && on(Version(0, 11, 0)))
        #expect(on(Version(0, 10, 3, prerelease: "rc.1")))
        #expect(!on(Version(0, 10, 2, prerelease: "rc.9")) && !on(Version(0, 10, 2, prerelease: "rc.10")))
        #expect(Capabilities(version: Version(0, 10, 1)).features.isEmpty)
        #expect(Capabilities(version: Version(0, 10, 0)).features.isEmpty)
        #expect(Version(0, 10, 1, prerelease: "rc.10") >= Version(0, 10, 1, prerelease: "rc.9"))
    }

    /// Every other feature is planned: no release turns one on until `shipped` names it.
    @Test func aNewerReleaseHasNoPlannedFeature() {
        #expect(Capabilities(version: Version(1, 0, 0)).features == [.selfCheck])
    }

    @Test func explicitFeatureSet() {
        let caps = Capabilities(version: Version(0, 10, 0), features: [.jsonMutations])
        #expect(caps.supports(.jsonMutations) && !caps.supports(.diffJSON))
    }
}
