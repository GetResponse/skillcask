import Foundation

/// One `skillcask` command line, built from typed parts so the app never concatenates strings into argv.
///
/// Rendering rules, all tested: `-g` comes first and only for `.personal`; `--json` is added where the CLI accepts
/// it; every value that comes from data (package, skill, query, path) follows a literal `--`, so a name starting with
/// `-` can never become a flag.
public struct Invocation: Hashable, Sendable {
    public enum InfoTarget: Hashable, Sendable {
        /// `info <skill>`: offline, reads the lock and the store (6 ms).
        case skill(String)
        /// `info <vendor/name>`: downloads the package's dist every time (seconds); never run it on selection.
        case package(String)
    }

    /// `search --skills-sh` / `--no-skills-sh` for one run, remembered in config.toml with `--remember`.
    public enum SkillsShChoice: Hashable, Sendable {
        case include
        case exclude
    }

    public enum Command: Hashable, Sendable {
        case version
        case status
        case audit
        case outdated
        case doctor(fix: Bool)
        case info(InfoTarget)
        case search(query: String, skillsSh: SkillsShChoice?, remember: Bool)
        /// `projects <dirs>`: the CLI refuses `-g`, so the scope only sets the working directory.
        case projects(roots: [URL])
        /// `diff [package]`: unified diff of what `update` would change; text, not JSON (until `diffJSON`).
        case diff(package: String?)
        /// `diff --to <version> -- <package>`: the diff to the newest version matching `version`, with NO cooldown
        /// (`src/main.rs` `Diff.to`, `src/commands.rs` `diff` → `candidate_at`); shipped in 0.9.1. For reading a
        /// version that still waits for the minimum release age; `update` would not lock it.
        case diffTo(package: String, version: String)
        case initialize
        case install(frozen: Bool)
        case update(packages: [String])
        case add(spec: String, repository: String?, adopt: Bool, rename: [String: String], skills: [String])
        case remove(packages: [String])
        /// `auth set <host>`: the token goes to stdin, never into argv. Like `auth remove`, the CLI refuses `-g`
        /// ("--global does not apply"), so the scope only sets the working directory.
        case authSet(host: String, username: String?)
        /// `auth remove <host>`: `username` must be the one the token was set with (the CLI's default otherwise).
        case authRemove(host: String, username: String?)
        /// `config --json -- <key>` (D48, `Capabilities.Feature.config`): `{"value", "from"}`, `null` and exit 1
        /// when nothing sets the key. Personal keys (`search.skills-sh`) need the personal scope (`-g`).
        case config(key: String)
        /// `config --json` (D48): every key with its effective value and layer, `{"file", "settings"}`; with `-g`
        /// the keys of config.toml as an empty project would see them.
        case configList
        /// `config -- <key> <value>…`: writes one setting of config.toml (personal) or skills.toml, one argument
        /// per entry of a list key; prints `set <key> in <file>`. An empty list cannot be written (no values reads
        /// the key): `configUnset` removes it.
        case configSet(key: String, values: [String])
        /// `config --unset -- <key>`: removes the key from the file; prints `removed <key> from <file>`, or a note
        /// that the file does not set it (exit 0 either way).
        case configUnset(key: String)
        /// `self-check --json` (D51): `{"version", "latest", "newer", "managed"}`, one anonymous request for the
        /// tap's cask file. Only behind `SelfCheckGate` (`CLIClient.selfCheck`): older CLIs would run a plugin.
        case selfCheck
    }

    /// What the child reads. Its descriptions and mirror never show the text (a token for `auth set`), so neither
    /// string interpolation, `dump` nor a test failure message of an `Invocation` can print it.
    public enum Stdin: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        /// `/dev/null`: the CLI only prompts on a terminal, so it never waits on us.
        case null
        /// Written and closed before the child reads; used for `auth set`. Never logged.
        case text(String)

        public var description: String {
            switch self {
            case .null: "null"
            case .text: "text(<redacted>)"
            }
        }

        public var debugDescription: String {
            description
        }

        public var customMirror: Mirror {
            Mirror(self, children: [], displayStyle: .enum)
        }
    }

    public let scope: Scope
    public let command: Command
    public let capabilities: Capabilities
    public let stdin: Stdin

    public init(_ command: Command, in scope: Scope, capabilities: Capabilities, stdin: Stdin = .null) throws(CLIError)
    {
        try Self.validate(command, capabilities: capabilities)
        self.command = command
        self.scope = scope
        self.capabilities = capabilities
        self.stdin = stdin
    }

    /// Changes skills.toml, skills.lock, the store or the links: serialised per scope by `MutationQueue`.
    public var isMutation: Bool {
        switch command {
        case .initialize, .install, .update, .add, .remove, .doctor(fix: true): true
        default: false
        }
    }

    /// Reads only: no file of the scope changes and the user does not wait on it as on a mutation, so it runs
    /// under `GuardedClient.readTimeout`. `search --remember` writes config.toml and stays out.
    public var isReadOnly: Bool {
        switch command {
        case .status, .audit, .outdated, .doctor(fix: false), .info, .diff, .diffTo, .projects, .config, .configList,
            .selfCheck:
            true
        case .search(_, _, let remember): !remember
        default: false
        }
    }

    /// Run in a project scope, the CLI resolves the project by walking up to the nearest folder with a
    /// skills.toml (`src/project.rs` `find_root`), so in a folder without one it acts on a parent project. Only
    /// `init` (which uses the folder itself), `projects` (directories as arguments), `--version` and `auth` (no
    /// project) are safe there; `GuardedClient` refuses the rest.
    public var needsManifest: Bool {
        guard !scope.isPersonal else { return false }
        switch command {
        case .version, .initialize, .projects, .authSet, .authRemove, .selfCheck: return false
        default: return true
        }
    }

    /// May talk to a registry or GitHub; shown with a network affordance and a Retry on exit 3.
    public var needsNetwork: Bool {
        switch command {
        case .outdated, .search, .diff, .diffTo, .info(.package), .install, .update, .add, .selfCheck: true
        default: false
        }
    }

    /// `--json` is on the command line, so stdout is a document (even on exit 1 for the read-only verbs).
    public var expectsDocument: Bool {
        switch command {
        case .status, .audit, .outdated, .doctor, .info, .search, .projects, .config, .configList, .selfCheck: true
        case .initialize, .install, .update, .add, .remove: capabilities.supports(.jsonMutations)
        case .version, .diff, .diffTo, .authSet, .authRemove, .configSet, .configUnset: false
        }
    }

    public var argv: [String] {
        var args: [String] = []
        if scope.isPersonal && acceptsGlobal {
            args.append("-g")
        }
        args += words
        return args
    }

    /// `skillcask -g add -- vendor/name`, for the Activity drawer and logs. The values of a key that may carry a
    /// credential (`ConfigKey.mayHoldCredentials`) are shown as the CLI prints URLs, and any `user:password@` left
    /// (a value without a scheme) is masked: no user name, password or query.
    public var displayCommand: String {
        var shown = argv
        if case .configSet(let key, let values) = command, ConfigKey.mayHoldCredentials(key) {
            shown.replaceSubrange(
                (shown.count - values.count)..., with: values.map { Redaction.credentials(in: Redaction.url($0)) })
        }
        return (["skillcask"] + shown.map(Self.quoted)).joined(separator: " ")
    }

    // MARK: - Rendering

    private var acceptsGlobal: Bool {
        switch command {
        case .version, .projects, .authSet, .authRemove, .selfCheck: false
        default: true
        }
    }

    private var json: [String] {
        expectsDocument ? ["--json"] : []
    }

    private var words: [String] {
        switch command {
        case .version:
            return ["--version"]
        case .status:
            return ["status"] + json
        case .audit:
            return ["audit"] + json
        case .outdated:
            return ["outdated"] + json
        case .doctor(let fix):
            return ["doctor"] + (fix ? ["--fix"] : []) + json
        case .info(.skill(let name)), .info(.package(let name)):
            return ["info"] + json + ["--", name]
        case .search(let query, let choice, let remember):
            var flags: [String] = []
            switch choice {
            case .include: flags.append("--skills-sh")
            case .exclude: flags.append("--no-skills-sh")
            case nil: break
            }
            if remember {
                flags.append("--remember")
            }
            return ["search"] + json + flags + ["--", query]
        case .projects(let roots):
            return ["projects"] + json + ["--"] + roots.map(\.path)
        case .diff(let package):
            return ["diff"] + (package.map { ["--", $0] } ?? [])
        case .diffTo(let package, let version):
            return ["diff", "--to", version, "--", package]
        case .initialize:
            return ["init"] + json
        case .install(let frozen):
            return ["install"] + (frozen ? ["--frozen"] : []) + json
        case .update(let packages):
            return ["update"] + json + (packages.isEmpty ? [] : ["--"] + packages)
        case .add(let spec, let repository, let adopt, let rename, let skills):
            var flags: [String] = []
            if let repository {
                flags += ["--repository", repository]
            }
            if adopt {
                flags.append("--adopt")
            }
            for (old, new) in rename.sorted(by: { $0.key < $1.key }) {
                flags += ["--rename", "\(old)=\(new)"]
            }
            for skill in skills {
                flags += ["--skill", skill]
            }
            return ["add"] + flags + json + ["--", spec]
        case .remove(let packages):
            return ["remove"] + json + ["--"] + packages
        case .authSet(let host, let username):
            return ["auth", "set"] + (username.map { ["--username", $0] } ?? []) + ["--", host]
        case .authRemove(let host, let username):
            return ["auth", "remove"] + (username.map { ["--username", $0] } ?? []) + ["--", host]
        case .config(let key):
            return ["config"] + json + ["--", key]
        case .configList:
            return ["config"] + json
        case .configSet(let key, let values):
            return ["config", "--", key] + values
        case .configUnset(let key):
            return ["config", "--unset", "--", key]
        case .selfCheck:
            return ["self-check"] + json
        }
    }

    private static func validate(_ command: Command, capabilities: Capabilities) throws(CLIError) {
        switch command {
        case .info(.skill(let name)), .info(.package(let name)):
            try require(!name.isEmpty, "info needs a package or skill name")
        case .search(let query, let choice, let remember):
            try require(!query.isEmpty, "search needs a query")
            try require(!remember || choice != nil, "search --remember needs a skills.sh choice")
        case .projects(let roots):
            try require(!roots.isEmpty, "projects needs at least one directory")
        case .diff(let package):
            try require(package?.isEmpty != true, "diff needs a package name or none")
        case .diffTo(let package, let version):
            try require(!package.isEmpty, "diff --to needs a package")
            try require(!version.isEmpty && !version.hasPrefix("-"), "diff --to needs a version")
        case .add(let spec, let repository, _, let rename, let skills):
            try require(!spec.isEmpty, "add needs a package spec")
            try require(repository?.isEmpty != true, "add --repository needs a name")
            if !rename.isEmpty {
                try feature(.addRename, capabilities, "add --rename")
                try require(rename.allSatisfy { !$0.key.isEmpty && !$0.value.isEmpty }, "add --rename needs old=new")
            }
            if !skills.isEmpty {
                try feature(.addSkill, capabilities, "add --skill")
                try require(skills.allSatisfy { !$0.isEmpty }, "add --skill needs a skill name")
            }
        case .remove(let packages):
            try require(!packages.isEmpty && packages.allSatisfy { !$0.isEmpty }, "remove needs at least one package")
        case .update(let packages):
            try require(packages.allSatisfy { !$0.isEmpty }, "update needs package names or none")
        case .authSet(let host, let username):
            try require(!host.isEmpty, "auth set needs a host")
            try require(username?.isEmpty != true, "auth set --username needs a name")
        case .authRemove(let host, let username):
            try require(!host.isEmpty, "auth remove needs a host")
            try require(username?.isEmpty != true, "auth remove --username needs a name")
        case .config(let key):
            try require(!key.isEmpty, "config needs a key")
        case .configSet(let key, let values):
            try require(
                !key.isEmpty && !values.isEmpty && values.allSatisfy { !$0.isEmpty }, "config needs a key and a value")
        case .configUnset(let key):
            try require(!key.isEmpty, "config --unset needs a key")
        case .version, .status, .audit, .outdated, .doctor, .initialize, .install, .configList, .selfCheck:
            break
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws(CLIError) {
        if !condition {
            throw .invalidInvocation(message)
        }
    }

    private static func feature(
        _ feature: Capabilities.Feature, _ capabilities: Capabilities, _ name: String
    ) throws(CLIError) {
        if !capabilities.supports(feature) {
            throw .unsupported(feature: name)
        }
    }

    private static func quoted(_ arg: String) -> String {
        let safe = arg.allSatisfy { $0.isLetter || $0.isNumber || "-_./=:@^~+,".contains($0) }
        return safe && !arg.isEmpty ? arg : "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
