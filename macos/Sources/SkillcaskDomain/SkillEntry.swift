import Foundation
import SkillcaskCore

/// One row of the skill list: a `status` entry joined with what `outdated` and `audit` say about it, reduced to
/// one `Health`. The id is stable across refreshes (the skill name, else the package name), so selection survives.
public struct SkillEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A skill installed from a package named in skills.toml.
        case package(String)
        /// A skill of a package pulled in by others.
        case dependency(String, via: [String])
        /// A row about a package rather than a skill: drift, not in the manifest, …
        case packageOnly(String)
        case project
        case handWritten
        case notManaged(adopt: String?)
    }

    public let id: String
    public let name: String
    public let kind: Kind
    /// The repository name or `git`, from the planned `status.source` key; nil until the CLI prints it.
    public let source: String?
    public let version: String?
    public let state: SkillState
    public let health: Health
    public let update: Update?
    public let findings: [AuditDocument.Finding]
    /// Relative to the scope root, from `audit`.
    public let path: String?
    public let description: String?
    /// What the text mentions, from the same `audit` row; nil when `audit` did not list the skill (a not managed
    /// skill on a CLI without the planned `auditNotManaged`, or no audit at all): "not audited", not "clean".
    public let reach: Reach?
    /// `status`'s `via` list as printed, kept for every kind: a package-only row of a drifted dependency carries it
    /// here, since its `Kind` has no room for it.
    public let via: [String]
    /// When the locked version was released, from `status`'s `released` key (D67, read from skills.lock); nil for a
    /// row without a lock entry, a lock without the time, or a CLI before D67.
    public let released: Date?

    public init(
        id: String, name: String, kind: Kind, source: String?, version: String?, state: SkillState, health: Health,
        update: Update?, findings: [AuditDocument.Finding], path: String?, description: String?, reach: Reach? = nil,
        via: [String] = [], released: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.version = version
        self.state = state
        self.health = health
        self.update = update
        self.findings = findings
        self.path = path
        self.description = description
        self.reach = reach
        self.via = via
        self.released = released
    }

    public var package: String? {
        switch kind {
        case .package(let name), .dependency(let name, _), .packageOnly(let name): name
        case .project, .handWritten, .notManaged: nil
        }
    }

    public var isProjectSkill: Bool {
        kind == .project
    }

    public var isNotManaged: Bool {
        if case .notManaged = kind { true } else { false }
    }

    public var hasUpdate: Bool {
        if case .updateAvailable = health { true } else { update?.available != nil }
    }
}
