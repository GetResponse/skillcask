import Foundation
import Testing

@testable import SkillcaskCore

/// `self-check --json` (D51) through `CLIClient.selfCheck`: the document, the CLI's own error lines on exit 3, an
/// older CLI's refusal read as unsupported, and the 2-minute limit of D35.
@Suite struct SelfCheckTests {
    /// Answers every run with one scripted result, or never (until cancelled); records the argv.
    final class Scripted: CLIClient, @unchecked Sendable {
        let stdout: String
        let stderr: String
        let exit: Int32
        let hangs: Bool
        private let lock = NSLock()
        private var seen: [Invocation] = []

        init(stdout: String = "", stderr: String = "", exit: Int32 = 0, hangs: Bool = false) {
            self.stdout = stdout
            self.stderr = stderr
            self.exit = exit
            self.hangs = hangs
        }

        var invocations: [Invocation] {
            lock.withLock { seen }
        }

        func run(
            _ invocation: Invocation, onLine: @escaping @Sendable (OutputLine) -> Void
        ) async throws(CLIError) -> RunResult {
            lock.withLock { seen.append(invocation) }
            if hangs {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                }
                throw .cancelled
            }
            return RunResult(invocation: invocation, status: .exited(exit), stdout: Data(stdout.utf8), stderr: stderr)
        }
    }

    let capabilities = Capabilities(version: Capabilities.minimum)
    let bundled = Locator.Choice.bundled(URL(fileURLWithPath: "/Applications/Skillcask.app/Contents/Helpers/skillcask"))
    static let document = #"{"latest":"0.10.2","newer":true,"version":"0.10.1"}"#

    /// 0.9.0–0.10.1 would run `skillcask-self-check` from PATH (plugin lookup): a configured or PATH CLI of those
    /// versions never receives the invocation; the bundled helper does even at 0.10.1 (a development bundle), and
    /// any CLI that reports 0.10.2 or newer does.
    @Test func onlyCLIsThatShipSelfCheckAreAsked() async throws {
        let configured = Locator.Choice.configured(URL(fileURLWithPath: "/usr/local/bin/skillcask"))
        let onPath = Locator.Choice.onPath(URL(fileURLWithPath: "/opt/homebrew/bin/skillcask"))
        for version in [Version(0, 9, 4), Version(0, 10, 1), Version(0, 10, 2, prerelease: "rc.1")] {
            for binary in [configured, onPath, nil] {
                let client = Scripted(stdout: Self.document)
                let outcome = try await client.selfCheck(binary: binary, capabilities: Capabilities(version: version))
                #expect(outcome == .unsupported, "\(version) \(String(describing: binary))")
                #expect(client.invocations.isEmpty, "nothing ran for \(version) \(String(describing: binary))")
            }
        }
        for (binary, version) in [
            (bundled, Version(0, 10, 1)), (bundled, Version(0, 9, 4)), (configured, Version(0, 10, 2)),
            (onPath, Version(0, 11, 0)),
        ] {
            let client = Scripted(stdout: Self.document)
            let outcome = try await client.selfCheck(binary: binary, capabilities: Capabilities(version: version))
            #expect(outcome == .checked(SelfCheckDocument(version: "0.10.1", latest: "0.10.2", newer: true)))
            #expect(client.invocations.map(\.argv) == [["self-check", "--json"]], "\(binary) \(version)")
        }
        #expect(SelfCheckGate.allows(binary: bundled, capabilities: Capabilities(version: Version(0, 10, 1))))
        #expect(!SelfCheckGate.allows(binary: configured, capabilities: Capabilities(version: Version(0, 10, 1))))
        #expect(SelfCheckGate.allows(binary: configured, capabilities: Capabilities(version: Version(0, 10, 2))))
    }

    /// The argv, the scope and the limits: no `-g`, no project needed, the 2 minutes of D35 and not the 15 of the
    /// registry reads.
    @Test func theInvocation() throws {
        let invocation = try Invocation(.selfCheck, in: .personal, capabilities: capabilities)
        #expect(invocation.argv == ["self-check", "--json"])
        #expect(invocation.displayCommand == "skillcask self-check --json")
        #expect(invocation.isReadOnly && invocation.expectsDocument && invocation.needsNetwork)
        #expect(!invocation.isMutation && !invocation.needsManifest)
        let project = try Invocation(
            .selfCheck, in: .project(URL(fileURLWithPath: "/tmp/none")), capabilities: capabilities)
        #expect(!project.needsManifest && project.argv == ["self-check", "--json"])
        #expect(GuardedClient(Scripted()).limit(for: invocation) == .seconds(120))
    }

    @Test func decodesTheDocument() async throws {
        let client = Scripted(stdout: #"{"latest":"0.10.2","newer":true,"version":"0.10.1"}"# + "\n")
        let outcome = try await client.selfCheck(binary: bundled, capabilities: capabilities)
        let document = SelfCheckDocument(version: "0.10.1", latest: "0.10.2", newer: true)
        #expect(outcome == .checked(document))
        #expect(document.latestVersion == Version(0, 10, 2))
        #expect(client.invocations.map(\.argv) == [["self-check", "--json"]])
        #expect(client.invocations.first?.scope == .personal)
    }

    /// The cask held nothing readable: the CLI warns on stderr and still exits 0 with `latest: null`.
    @Test func aNullLatestIsADocumentNotAnError() async throws {
        let client = Scripted(
            stdout: #"{"latest":null,"newer":false,"version":"0.10.1"}"#,
            stderr: "warning: https://raw.githubusercontent.com/…: no version \"X.Y.Z\" skillcask can read\n")
        let outcome = try await client.selfCheck(binary: bundled, capabilities: capabilities)
        #expect(outcome == .checked(SelfCheckDocument(version: "0.10.1", latest: nil, newer: false)))
        if case .checked(let document) = outcome {
            #expect(document.latestVersion == nil)
        }
    }

    /// A `latest` that is not a strict version never becomes a `Version`, whatever `newer` says.
    @Test(arguments: ["v0.10.2", "0.10.2+b", "0.10", "0.10.2 ", "javascript:alert(1)", "0.10.2-rc_1"])
    func aLooseLatestIsDropped(latest: String) {
        #expect(SelfCheckDocument(version: "0.10.1", latest: latest, newer: true).latestVersion == nil)
    }

    /// Exit 3 keeps the CLI's `error:` and `hint:` lines for the alert.
    @Test func exitThreeIsANetworkFailureWithTheCLIsWords() async {
        let stderr = """
            warning: https://raw.githubusercontent.com/GetResponse/homebrew-tap/main/Casks/skillcask-app.rb: io: Connection refused (os error 61); retrying in 1s
            error: https://raw.githubusercontent.com/GetResponse/homebrew-tap/main/Casks/skillcask-app.rb: io: Connection refused (os error 61)
              hint: check the connection; releases are listed at https://github.com/GetResponse/skillcask/releases

            """
        let client = Scripted(stderr: stderr, exit: 3)
        await #expect(
            throws: CLIError.failed(
                code: .network,
                message:
                    "https://raw.githubusercontent.com/GetResponse/homebrew-tap/main/Casks/skillcask-app.rb: io: Connection refused (os error 61)",
                hint: "check the connection; releases are listed at https://github.com/GetResponse/skillcask/releases",
                stderr: stderr)
        ) {
            try await client.selfCheck(binary: bundled, capabilities: capabilities)
        }
    }

    /// An older CLI (a path set in Settings) takes `self-check` for a plugin it cannot find: unsupported, no error.
    @Test(arguments: [
        (Int32(1), "error: unknown command \"self-check\" (no skillcask-self-check on PATH)\n"),
        (1, "error: unknown command \"self-check\"\n"),
        (2, "error: unrecognized subcommand 'self-check'\n\nUsage: skillcask [OPTIONS] <COMMAND>\n"),
    ])
    func anOlderCLIIsUnsupported(exit: Int32, stderr: String) async throws {
        let outcome = try await Scripted(stderr: stderr, exit: exit)
            .selfCheck(binary: bundled, capabilities: capabilities)
        #expect(outcome == .unsupported)
    }

    /// Other failures stay failures, even ones that mention the command.
    @Test(arguments: [
        (Int32(1), "error: unknown command \"self-checks\" (no skillcask-self-checks on PATH)\n"),
        (3, "error: unknown command \"self-check\"\n"),
        (5, "error: io: permission denied\n"),
        (101, "thread 'main' panicked\n"),
    ])
    func otherFailuresThrow(exit: Int32, stderr: String) async {
        await #expect(throws: CLIError.self) {
            try await Scripted(stderr: stderr, exit: exit).selfCheck(binary: bundled, capabilities: capabilities)
        }
    }

    /// Exit 0 with something that is not the document: a decode error, not a silent "up to date".
    @Test func exitZeroWithoutTheDocumentThrows() async {
        await #expect(throws: CLIError.noDocument) {
            try await Scripted().selfCheck(binary: bundled, capabilities: capabilities)
        }
        await #expect(throws: CLIError.self) {
            try await Scripted(stdout: "skillcask 0.10.1, latest 0.10.2: update available\n")
                .selfCheck(binary: bundled, capabilities: capabilities)
        }
    }

    /// A check that never answers is stopped after the read limit.
    @Test(.timeLimit(.minutes(1))) func aHangingCheckTimesOut() async {
        let guarded = GuardedClient(Scripted(hangs: true), readTimeout: .milliseconds(50))
        await #expect(throws: CLIError.timedOut(after: .milliseconds(50))) {
            try await guarded.selfCheck(binary: bundled, capabilities: capabilities)
        }
    }
}

/// `Version.init?(strict:)`: `^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$` in ASCII and nothing else.
@Suite struct StrictVersionTests {
    @Test(arguments: [
        ("0.10.1", Version(0, 10, 1)), ("1.0.0-rc.1", Version(1, 0, 0, prerelease: "rc.1")),
        ("10.20.30-a-b.C9", Version(10, 20, 30, prerelease: "a-b.C9")), ("0.0.0", Version(0, 0, 0)),
    ])
    func accepts(text: String, expected: Version) {
        #expect(Version(strict: text) == expected)
        #expect(expected.isStrict)
    }

    @Test(arguments: [
        "", "v0.10.1", "0.10", "0.10.1.2", "0.10.1+build", "0.10.1-", "0.10.1-rc_1", " 0.10.1", "0.10.1\n",
        "+1.0.0", "1.+0.0", "1.-0.0", "\u{0661}.0.0", "1.0.0-rc.1\u{202E}", "99999999999999999999.0.0", "1..0",
        "-1.0.0",
    ])
    func rejects(text: String) {
        #expect(Version(strict: text) == nil, "\(text.debugDescription)")
    }

    @Test func aBuiltPrereleaseTheCaskCouldNotHoldIsNotStrict() {
        #expect(!Version(1, 0, 0, prerelease: "rc_1").isStrict)
        #expect(!Version(1, 0, 0, prerelease: "").isStrict)
        #expect(Version(1, 0, 0, prerelease: "rc.1").isStrict)
    }
}
