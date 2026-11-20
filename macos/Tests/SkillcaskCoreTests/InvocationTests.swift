import Foundation
import Testing

@testable import SkillcaskCore

@Suite struct InvocationTests {
    let project = Scope.project(URL(fileURLWithPath: "/tmp/p"))
    let caps = Fixture.capabilities
    let all = Capabilities(version: Version(0, 10, 0), features: Set(Capabilities.Feature.allCases))

    func argv(
        _ command: Invocation.Command, in scope: Scope? = nil, capabilities: Capabilities? = nil
    ) throws -> [String] {
        try Invocation(command, in: scope ?? project, capabilities: capabilities ?? caps).argv
    }

    @Test(arguments: [
        (Invocation.Command.version, ["--version"]),
        (.status, ["status", "--json"]),
        (.audit, ["audit", "--json"]),
        (.outdated, ["outdated", "--json"]),
        (.doctor(fix: false), ["doctor", "--json"]),
        (.doctor(fix: true), ["doctor", "--fix", "--json"]),
        (.info(.skill("notes")), ["info", "--json", "--", "notes"]),
        (.info(.package("acme/one")), ["info", "--json", "--", "acme/one"]),
        (.search(query: "jira", skillsSh: nil, remember: false), ["search", "--json", "--", "jira"]),
        (
            .search(query: "-x", skillsSh: .include, remember: true),
            ["search", "--json", "--skills-sh", "--remember", "--", "-x"]
        ),
        (.search(query: "q", skillsSh: .exclude, remember: false), ["search", "--json", "--no-skills-sh", "--", "q"]),
        (.diff(package: nil), ["diff"]),
        (.diff(package: "acme/one"), ["diff", "--", "acme/one"]),
        // `diff --to` (no cooldown, src/main.rs `Diff.to`): reads a version that still waits.
        (.diffTo(package: "acme/one", version: "4.3.0"), ["diff", "--to", "4.3.0", "--", "acme/one"]),
        (.initialize, ["init"]),
        (.install(frozen: false), ["install"]),
        (.install(frozen: true), ["install", "--frozen"]),
        (.update(packages: []), ["update"]),
        (.update(packages: ["acme/one", "-g"]), ["update", "--", "acme/one", "-g"]),
        (
            .add(spec: "acme/one@^1", repository: nil, adopt: false, rename: [:], skills: []),
            ["add", "--", "acme/one@^1"]
        ),
        (
            .add(spec: "github:o/r", repository: "fix", adopt: true, rename: [:], skills: []),
            ["add", "--repository", "fix", "--adopt", "--", "github:o/r"]
        ),
        (.remove(packages: ["acme/one"]), ["remove", "--", "acme/one"]),
        (
            .authSet(host: "api.github.com", username: "oauth2"),
            ["auth", "set", "--username", "oauth2", "--", "api.github.com"]
        ),
        (.authSet(host: "gitlab.example", username: nil), ["auth", "set", "--", "gitlab.example"]),
        (.authRemove(host: "gitlab.example", username: nil), ["auth", "remove", "--", "gitlab.example"]),
        (
            .authRemove(host: "api.github.com", username: "oauth2"),
            ["auth", "remove", "--username", "oauth2", "--", "api.github.com"]
        ),
    ])
    func projectArgv(command: Invocation.Command, expected: [String]) throws {
        #expect(try argv(command) == expected)
    }

    @Test func personalScopePutsGlobalFirst() throws {
        #expect(try argv(.status, in: .personal) == ["-g", "status", "--json"])
        #expect(
            try argv(.add(spec: "a/b", repository: nil, adopt: true, rename: [:], skills: []), in: .personal) == [
                "-g", "add", "--adopt", "--", "a/b",
            ])
    }

    /// The CLI refuses `-g` on `auth` ("--global does not apply to this command"), so the personal scope adds none.
    @Test func authNeverTakesGlobal() throws {
        #expect(try argv(.authSet(host: "h", username: nil), in: .personal) == ["auth", "set", "--", "h"])
        #expect(
            try argv(.authRemove(host: "h", username: "oauth2"), in: .personal) == [
                "auth", "remove", "--username", "oauth2", "--", "h",
            ])
    }

    @Test func versionAndProjectsNeverTakeGlobal() throws {
        #expect(try argv(.version, in: .personal) == ["--version"])
        let roots = [URL(fileURLWithPath: "/Users/me/www"), URL(fileURLWithPath: "/tmp/-x")]
        #expect(
            try argv(.projects(roots: roots), in: .personal) == [
                "projects", "--json", "--", "/Users/me/www", "/tmp/-x",
            ])
    }

    @Test func mutationsNeverGetJSON() throws {
        #expect(try argv(.initialize, capabilities: all) == ["init"])
        #expect(try argv(.install(frozen: false), capabilities: all) == ["install"])
        #expect(try argv(.update(packages: ["a/b"]), capabilities: all) == ["update", "--", "a/b"])
        #expect(try argv(.remove(packages: ["a/b"]), capabilities: all) == ["remove", "--", "a/b"])
        let add = Invocation.Command.add(
            spec: "github:o/r@^1", repository: nil, adopt: false, rename: ["x": "y", "a": "b"], skills: ["s1", "s2"])
        #expect(
            try argv(add, capabilities: all) == [
                "add", "--rename", "a=b", "--rename", "x=y", "--", "github:o/r/s1@^1", "github:o/r/s2@^1",
            ])
        #expect(try !Invocation(.initialize, in: project, capabilities: all).expectsDocument)
    }

    @Test func renameAndSkillNeedTheirFeatures() throws {
        let rename = Invocation.Command.add(spec: "a/b", repository: nil, adopt: false, rename: ["x": "y"], skills: [])
        #expect(throws: CLIError.unsupported(feature: "add --rename")) {
            try Invocation(rename, in: project, capabilities: caps)
        }
        let skill = Invocation.Command.add(
            spec: "github:o/r", repository: nil, adopt: false, rename: [:], skills: ["s"])
        #expect(throws: CLIError.unsupported(feature: "add with several specs")) {
            try Invocation(skill, in: project, capabilities: caps)
        }
        for spec in ["a/b", "github:o/r/s"] {
            let notRepo = Invocation.Command.add(spec: spec, repository: nil, adopt: false, rename: [:], skills: ["s"])
            #expect(throws: CLIError.self) { try Invocation(notRepo, in: project, capabilities: all) }
        }
    }

    @Test(arguments: [
        Invocation.Command.info(.skill("")),
        .search(query: "", skillsSh: nil, remember: false),
        .search(query: "q", skillsSh: nil, remember: true),
        .projects(roots: []),
        .diff(package: ""),
        .diffTo(package: "", version: "1.0.0"),
        .diffTo(package: "a/b", version: ""),
        .diffTo(package: "a/b", version: "-g"),
        .add(spec: "", repository: nil, adopt: false, rename: [:], skills: []),
        .add(spec: "a/b", repository: "", adopt: false, rename: [:], skills: []),
        .remove(packages: []),
        .remove(packages: [""]),
        .update(packages: [""]),
        .authSet(host: "", username: nil),
        .authSet(host: "h", username: ""),
        .authRemove(host: "", username: nil),
        .authRemove(host: "h", username: ""),
    ])
    func emptyDataIsRejected(command: Invocation.Command) {
        #expect(throws: CLIError.self) { try Invocation(command, in: project, capabilities: caps) }
    }

    @Test func classification() throws {
        let mutations: [Invocation.Command] = [
            .initialize, .install(frozen: false), .update(packages: []), .remove(packages: ["a"]), .doctor(fix: true),
        ]
        for command in mutations {
            #expect(try Invocation(command, in: project, capabilities: caps).isMutation, "\(command)")
        }
        for command in [
            Invocation.Command.status, .doctor(fix: false), .outdated,
            .search(query: "q", skillsSh: nil, remember: false), .version,
        ] {
            #expect(try !Invocation(command, in: project, capabilities: caps).isMutation, "\(command)")
        }
        #expect(try Invocation(.info(.package("a/b")), in: project, capabilities: caps).needsNetwork)
        #expect(try !Invocation(.info(.skill("b")), in: project, capabilities: caps).needsNetwork)
        #expect(try !Invocation(.status, in: project, capabilities: caps).needsNetwork)
        #expect(try Invocation(.outdated, in: project, capabilities: caps).needsNetwork)
    }

    /// The reads that run under `GuardedClient.readTimeout`: no mutation, and not `search --remember`, which
    /// writes config.toml.
    @Test func readOnlyCommandsAreTheOnesWithATimeout() throws {
        let reads: [Invocation.Command] = [
            .status, .audit, .outdated, .doctor(fix: false), .info(.skill("a")), .info(.package("a/b")),
            .search(query: "q", skillsSh: nil, remember: false), .diff(package: nil),
            .diffTo(package: "a/b", version: "1.0"), .projects(roots: [URL(fileURLWithPath: "/tmp")]),
            .config(key: "search.skills-sh"), .configList, .selfCheck,
        ]
        for command in reads {
            #expect(try Invocation(command, in: project, capabilities: all).isReadOnly, "\(command)")
        }
        let others: [Invocation.Command] = [
            .version, .initialize, .install(frozen: false), .update(packages: []), .remove(packages: ["a"]),
            .doctor(fix: true), .search(query: "q", skillsSh: .include, remember: true),
            .authSet(host: "h", username: nil), .configSet(key: "search.skills-sh", values: ["true"]),
            .configUnset(key: "policy.enforce"),
        ]
        for command in others {
            #expect(try !Invocation(command, in: project, capabilities: all).isReadOnly, "\(command)")
        }
    }

    /// In a project folder only `init`, `projects`, `--version` and `auth` may run without skills.toml: everything
    /// else would make the CLI walk up to a parent project (`src/project.rs` `find_root`). The personal scope has
    /// no such walk.
    @Test func whatNeedsAManifest() throws {
        for command in [Invocation.Command.version, .initialize, .projects(roots: [URL(fileURLWithPath: "/tmp")])] {
            #expect(try !Invocation(command, in: project, capabilities: caps).needsManifest, "\(command)")
        }
        #expect(try !Invocation(.authSet(host: "h", username: nil), in: project, capabilities: caps).needsManifest)
        for command in [
            Invocation.Command.status, .audit, .doctor(fix: false), .doctor(fix: true), .install(frozen: true),
            .remove(packages: ["a"]), .search(query: "q", skillsSh: nil, remember: false),
        ] {
            #expect(try Invocation(command, in: project, capabilities: caps).needsManifest, "\(command)")
            #expect(try !Invocation(command, in: .personal, capabilities: caps).needsManifest, "\(command)")
        }
    }

    /// `config` (D48): the read prints `{"value", "from"}`; the write is a plain line. Every supported CLI has it,
    /// and a personal key goes through `-g` (the CLI refuses it in a project).
    @Test func configCommands() throws {
        #expect(
            try argv(.config(key: "search.skills-sh"), in: .personal, capabilities: all)
                == ["-g", "config", "--json", "--", "search.skills-sh"])
        #expect(
            try argv(.configSet(key: "search.skills-sh", values: ["false"]), in: .personal, capabilities: all)
                == ["-g", "config", "--", "search.skills-sh", "false"])
        #expect(
            try argv(.config(key: "search.skills-sh"), in: .personal, capabilities: caps)
                == ["-g", "config", "--json", "--", "search.skills-sh"])
        #expect(throws: CLIError.self) {
            try Invocation(.configSet(key: "search.skills-sh", values: [""]), in: .personal, capabilities: all)
        }
        #expect(try Invocation(.config(key: "k"), in: .personal, capabilities: all).expectsDocument)
        #expect(try !Invocation(.configSet(key: "k", values: ["v"]), in: .personal, capabilities: all).isMutation)
    }

    /// Settings › Global: the whole list with `--json`; a list key gets one argument per entry after `--`, so an
    /// entry starting with `-` stays a value; `--unset` goes before `--`. The minimum CLI runs them all.
    @Test func globalConfigCommands() throws {
        #expect(try argv(.configList, in: .personal, capabilities: all) == ["-g", "config", "--json"])
        #expect(
            try argv(.configSet(key: "agents.targets", values: ["claude", "-x"]), in: .personal, capabilities: all)
                == ["-g", "config", "--", "agents.targets", "claude", "-x"])
        #expect(
            try argv(.configUnset(key: "policy.enforce"), in: .personal, capabilities: all)
                == ["-g", "config", "--unset", "--", "policy.enforce"])
        for command in [Invocation.Command.configList, .configUnset(key: "k"), .configSet(key: "k", values: ["v"])] {
            #expect(throws: Never.self) { try Invocation(command, in: .personal, capabilities: caps) }
        }
        for command in [Invocation.Command.configSet(key: "k", values: []), .configUnset(key: "")] {
            #expect(throws: CLIError.self) { try Invocation(command, in: .personal, capabilities: all) }
        }
        let list = try Invocation(.configList, in: .personal, capabilities: all)
        #expect(list.isReadOnly && list.expectsDocument && !list.isMutation)
        let unset = try Invocation(.configUnset(key: "k"), in: .personal, capabilities: all)
        #expect(!unset.isReadOnly && !unset.expectsDocument && !unset.isMutation)
    }

    /// `allow-sources` URLs may carry a token: argv has them as typed, the Activity line as the CLI prints them.
    @Test func credentialBearingValuesAreRedactedInTheDisplayCommand() throws {
        let typed = "https://user:tok@repo.example/p?x=1"
        let secret = try Invocation(
            .configSet(key: "policy.allow-sources", values: ["packagist", typed]), in: .personal, capabilities: all)
        #expect(secret.argv.last == typed)
        #expect(
            secret.displayCommand
                == "skillcask -g config -- policy.allow-sources packagist 'https://repo.example/p?%E2%80%A6'")
        #expect(!secret.displayCommand.contains("tok"))
        let bare = try Invocation(
            .configSet(key: "policy.allow-sources", values: ["u:p@h.example/x"]), in: .personal, capabilities: all)
        #expect(bare.displayCommand == "skillcask -g config -- policy.allow-sources '••••@h.example/x'")
        let plain = try Invocation(
            .configSet(key: "agents.targets", values: ["https://user:tok@x.example"]), in: .personal, capabilities: all)
        #expect(plain.displayCommand.contains("tok"), "only allow-sources is redacted")
    }

    @Test func displayCommandQuotesOnlyWhatNeedsIt() throws {
        let plain = try Invocation(
            .add(spec: "acme/one@^1.0", repository: nil, adopt: false, rename: [:], skills: []), in: .personal,
            capabilities: caps)
        #expect(plain.displayCommand == "skillcask -g add -- acme/one@^1.0")
        let spaced = try Invocation(
            .search(query: "two words'", skillsSh: nil, remember: false), in: project, capabilities: caps)
        #expect(spaced.displayCommand == #"skillcask search --json -- 'two words'\'''"#)
    }

    @Test func stdinIsNullUnlessGiven() throws {
        #expect(try Invocation(.status, in: project, capabilities: caps).stdin == .null)
        let auth = try Invocation(
            .authSet(host: "h", username: nil), in: project, capabilities: caps, stdin: .text("tok"))
        #expect(auth.stdin == .text("tok") && !auth.displayCommand.contains("tok"))
    }

    /// Interpolation, `debugDescription` and `dump` of an invocation never show what it writes to stdin.
    @Test func stdinTextIsRedactedEverywhere() throws {
        let secret = "ghp_secretTokenValue123"
        let auth = try Invocation(
            .authSet(host: "api.github.com", username: "oauth2"), in: project, capabilities: caps,
            stdin: .text(secret))
        var dumped = ""
        dump(auth, to: &dumped)
        for text in [String(describing: auth), String(reflecting: auth), "\(auth.stdin)", dumped] {
            #expect(!text.contains(secret))
        }
    }
}

@Suite struct ScopeTests {
    @Test func projectAtResolvesTildeAndDots() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(Scope.project(at: "~/www/../www/a").root.path == "\(home)/www/a")
        #expect(Scope.personal.root.path == home)
        #expect(Scope.personal.isPersonal && !Scope.project(at: "/tmp").isPersonal)
    }
}
