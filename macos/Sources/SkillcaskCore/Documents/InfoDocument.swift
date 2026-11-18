/// `info --json` (D32, D41). Two shapes share the verb: a package (`package`, `versions`, `skills`, …, downloaded
/// from the registry) and a skill name (`skill`, `kind`, `path`, read from the lock and the store).
public struct InfoDocument: Decodable, Hashable, Sendable {
    public struct Skill: Decodable, Hashable, Sendable {
        public let name: String
        public let description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    public enum Abandoned: Hashable, Sendable {
        case withoutReplacement
        case replacedBy(String)
    }

    public let package: String?
    public let source: String?
    public let repository: String?
    public let version: String?
    public let locked: Bool?
    public let description: String?
    public let license: [String]
    /// `true`, a replacement package name, or absent/`false`/`null` when the package is maintained.
    public let abandoned: Abandoned?
    public let versions: [String]
    /// Since D67: when entries of `versions` were released, keyed as `versions` spells them (RFC 3339). A version
    /// missing here is not known: Composer dates every version, GitHub and git only the shown or locked one. Empty
    /// from an older CLI or when the key does not decode.
    public let versionsReleased: [String: String]
    public let requires: [String: String]
    public let skills: [Skill]
    /// Why the package is in the lock: `acme/one: in skills.toml as "^1.0"`.
    public let why: [String]

    public let skill: String?
    /// `package`, `project` or `hand-written` (D41, `src/commands.rs` `why_skill`).
    public let kind: String?
    /// Relative to the scope root.
    public let path: String?
    public let from: String?
    /// Since D67: when the installed version was released, from skills.lock (RFC 3339); nil when the lock has no
    /// time, for a project or hand-written skill, or from an older CLI.
    public let released: String?

    enum CodingKeys: String, CodingKey {
        case package
        case source
        case repository
        case version
        case locked
        case description
        case license
        case abandoned
        case versions
        case versionsReleased = "versions-released"
        case requires
        case skills
        case why
        case skill
        case kind
        case path
        case from
        case released
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        package = try c.decodeIfPresent(String.self, forKey: .package)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        repository = try c.decodeIfPresent(String.self, forKey: .repository)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        license = try c.decodeIfPresent([String].self, forKey: .license) ?? []
        abandoned = try Self.abandoned(in: c)
        versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        // Tolerant: a value that is `null` means "not known"; a key of another shape leaves the map empty.
        versionsReleased =
            (try? c.decodeIfPresent([String: String?].self, forKey: .versionsReleased))?.compactMapValues { $0 } ?? [:]
        requires = try c.decodeIfPresent([String: String].self, forKey: .requires) ?? [:]
        skills = try c.decodeIfPresent([Skill].self, forKey: .skills) ?? []
        why = try c.decodeIfPresent([String].self, forKey: .why) ?? []
        skill = try c.decodeIfPresent(String.self, forKey: .skill)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        released = try? c.decodeIfPresent(String.self, forKey: .released)
    }

    private static func abandoned(in c: KeyedDecodingContainer<CodingKeys>) throws -> Abandoned? {
        if let flag = try? c.decodeIfPresent(Bool.self, forKey: .abandoned) {
            return flag ? .withoutReplacement : nil
        }
        return try c.decodeIfPresent(String.self, forKey: .abandoned).map(Abandoned.replacedBy)
    }
}
