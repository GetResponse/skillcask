/// `status --json` (D32): every skill the scope knows about, the effective policy, the agent targets and the
/// repositories. Exit 1 with this document when any entry is unhealthy. Keys are only ever added, so unknown keys
/// are ignored and later keys are optional.
public struct StatusDocument: Decodable, Hashable, Sendable {
    public struct Entry: Decodable, Hashable, Sendable {
        /// The package name alone; nil for a project, hand-written or not managed skill.
        public let package: String?
        /// The packages that require this one when it is a dependency rather than a manifest entry (`via`, `null`
        /// otherwise).
        public let via: [String]
        public let version: String?
        public let skill: String?
        /// The CLI's state word (`ok`, `modified`, `not installed`, `project`, `not managed`, …) or a drift sentence.
        public let state: String
        public let ok: Bool
        /// For a `not managed` personal skill: the `add --adopt` source recorded by `npx skills` (D38).
        public let adopt: String?
        /// Planned (`statusDescription`): the skill's front-matter description.
        public let description: String?
        /// Planned (`statusSource`): the repository the package came from (`packagist`, `github`, a custom
        /// repository name) or `git` for a git URL; nil for project and hand-written skills. A not managed skill
        /// carries the source `adopt` was recorded from when known, nil otherwise.
        public let source: String?

        enum CodingKeys: String, CodingKey {
            case package
            case via
            case version
            case skill
            case state
            case ok
            case adopt
            case description
            case source
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            package = try c.decodeIfPresent(String.self, forKey: .package)
            via = try c.decodeIfPresent([String].self, forKey: .via) ?? []
            version = try c.decodeIfPresent(String.self, forKey: .version)
            skill = try c.decodeIfPresent(String.self, forKey: .skill)
            state = try c.decode(String.self, forKey: .state)
            ok = try c.decode(Bool.self, forKey: .ok)
            adopt = try c.decodeIfPresent(String.self, forKey: .adopt)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            source = try c.decodeIfPresent(String.self, forKey: .source)
        }
    }

    /// One effective policy key with where it came from (`skills.toml`, `config.toml`, `env`, `default`).
    public struct Policy: Decodable, Hashable, Sendable {
        public let value: JSONValue
        public let from: String
    }

    public struct Targets: Decodable, Hashable, Sendable {
        public let entries: [String]
        public let dirs: [String]
        /// `skills.toml`, `config.toml` or `default`.
        public let from: String?
        /// The project skills directory (`[agents] local`), relative to the project root, no `./` or trailing `/`;
        /// `null` with `--global`. Added after 0.10.2 (add-only, D32): nil from an older CLI, read as `.skills`.
        public let local: String?

        public init(entries: [String], dirs: [String], from: String?, local: String? = nil) {
            self.entries = entries
            self.dirs = dirs
            self.from = from
            self.local = local
        }
    }

    /// Since 0.9.0 (D42): every source the scope may resolve in.
    public struct Repository: Decodable, Hashable, Sendable {
        public let name: String
        public let type: String
        public let url: String
        public let allowed: Bool
    }

    public let ok: Bool
    public let entries: [Entry]
    public let policy: [String: Policy]
    public let targets: Targets?
    public let repositories: [Repository]

    enum CodingKeys: String, CodingKey {
        case ok
        case entries
        case policy
        case targets
        case repositories
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        entries = try c.decode([Entry].self, forKey: .entries)
        policy = try c.decodeIfPresent([String: Policy].self, forKey: .policy) ?? [:]
        targets = try c.decodeIfPresent(Targets.self, forKey: .targets)
        repositories = try c.decodeIfPresent([Repository].self, forKey: .repositories) ?? []
    }
}
