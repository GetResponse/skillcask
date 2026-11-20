import Foundation
import SkillcaskCore

/// A `CLIClient` that answers from the design fixtures without a process: the api, website and personal scopes of
/// the boards, one JSON document per read-only command, a short transcript and exit 0 for a mutation. Preview and
/// demo mode only (`Boot.fixtures`, `SKILLCASK_UI_FIXTURES=1`), never the shipped behaviour: the app always
/// talks to the real binary unless that variable is set.
public struct FixtureCLIClient: CLIClient {
    /// How long a mutation "runs", so the progress header is visible in the demo.
    public var mutationDelay: Duration

    public init(mutationDelay: Duration = .milliseconds(600)) {
        self.mutationDelay = mutationDelay
    }

    /// The board scope a `Scope` stands for: `~/work/api` → `api`, `~/work/site` → `website`, personal → `personal`.
    static func board(for scope: Scope) -> String {
        switch scope {
        case .personal: return "personal"
        case .project(let url): return url.lastPathComponent == "site" ? "website" : "api"
        }
    }

    /// The info fixture of a skill the boards know; nil makes `info` fail as the CLI would for an unknown skill.
    static func infoFixture(for skill: String) -> String? {
        switch skill {
        case "pdf", "test-writer": "info.package.anthropics-skills"
        case "jira-syntax", "jira-communication": "info.package.netresearch-agent-jira-skill"
        case "legacy-lint": "info.package.acme-lint"
        case "safe-refactor": "info.package.juliusbrussee-safe-refactor"
        case "commit-message": "info.package.acme-commit"
        case "my-notes": "info.skill.my-notes"
        default: nil
        }
    }

    /// The fixture document of `invocation`'s command for its scope's board; mutations stream `Transcripts.sync`.
    public func run(
        _ invocation: Invocation, onLine: @escaping @Sendable (OutputLine) -> Void
    ) async throws(CLIError) -> RunResult {
        let board = Self.board(for: invocation.scope)
        switch invocation.command {
        case .version:
            return answer(invocation, text: "skillcask 0.9.4 (fixture)\n")
        case .status:
            return answer(invocation, fixture: "status.\(board)", exit: board == "api" ? 1 : 0)
        case .audit:
            return answer(invocation, fixture: "audit.\(board)")
        case .doctor(fix: false):
            return answer(invocation, fixture: "doctor.\(board)", exit: board == "api" ? 1 : 0)
        case .outdated:
            return answer(invocation, fixture: "outdated.\(board)")
        case .projects:
            return answer(invocation, fixture: "projects")
        case .info(.skill(let name)), .info(.package(let name)):
            guard let fixture = Self.infoFixture(for: name) else {
                throw .failed(code: .problem, message: "no package or skill named \(name)", hint: nil, stderr: "")
            }
            return answer(invocation, fixture: fixture)
        case .search:
            return answer(invocation, fixture: "search.jira")
        case .diff(let package):
            // Update All (no package) reviews pdf and review-pr, as ReviewUpdate-States draws it.
            let review = package == nil ? DesignFixtures.text("diff.review-pr", "txt") : ""
            return answer(invocation, text: DesignFixtures.text("diff.pdf", "txt") + review)
        case .diffTo:
            // Read the changes… of the cooldown: jira-communication's waiting 4.3.0, cooldown not applied.
            return answer(invocation, text: DesignFixtures.text("diff.jira-communication", "txt"))
        case .install, .doctor(fix: true), .update, .add, .addMany, .remove, .initialize:
            for line in DesignFixtures.Transcripts.sync {
                onLine(.stdout(line))
                try? await Task.sleep(for: mutationDelay / DesignFixtures.Transcripts.sync.count)
            }
            if Task.isCancelled {
                throw .cancelled
            }
            return RunResult(invocation: invocation, status: .exited(0), stdout: Data(), stderr: "")
        case .authSet, .authRemove, .configSet, .configUnset:
            return RunResult(invocation: invocation, status: .exited(0), stdout: Data(), stderr: "")
        case .config:
            // Nothing set: what `config --json` prints for a key no layer sets, with its exit 1.
            return answer(invocation, text: #"{"from":null,"value":null}"#, exit: 1)
        case .configList:
            return answer(invocation, fixture: "config.global")
        case .selfCheck:
            // Never asked: the update check is off in fixture runs. Up to date, should a preview ever ask.
            return answer(invocation, text: #"{"latest":"0.9.4","newer":false,"version":"0.9.4"}"#)
        }
    }

    private func answer(_ invocation: Invocation, fixture: String, exit: Int32 = 0) -> RunResult {
        answer(invocation, text: DesignFixtures.text(fixture, "json"), exit: exit)
    }

    private func answer(_ invocation: Invocation, text: String, exit: Int32 = 0) -> RunResult {
        RunResult(invocation: invocation, status: .exited(exit), stdout: Data(text.utf8), stderr: "")
    }
}
