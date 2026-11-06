import Foundation
import SkillcaskCore

/// Everything the main window shows for one scope, built from the documents of one refresh. `outdated` is
/// optional because updates are only known after an explicit check.
public struct ScopeSnapshot: Hashable, Sendable {
    public struct PolicyRow: Hashable, Sendable, Identifiable {
        /// The policy keys of `src/policy.rs`, typed; a key this app does not know survives as `.other`.
        public enum Kind: Hashable, Sendable {
            case allowSources
            case minReleaseAge
            case allowRanges
            case other(String)

            public init(key: String) {
                switch key {
                case "allow-sources": self = .allowSources
                case "min-release-age": self = .minReleaseAge
                case "allow-ranges": self = .allowRanges
                default: self = .other(key)
                }
            }

            /// The Overview board's row order: minimum release age, allowed sources, ranges allowed, then any other
            /// key; ties (two unknown keys) fall back to the key's spelling.
            public var rank: Int {
                switch self {
                case .minReleaseAge: 0
                case .allowSources: 1
                case .allowRanges: 2
                case .other: 3
                }
            }

            /// Whether the row of `key` comes before the row of `other` in the board's order.
            public static func precedes(_ key: String, _ other: String) -> Bool {
                let (left, right) = (Kind(key: key).rank, Kind(key: other).rank)
                return left == right ? key < other : left < right
            }
        }

        /// `0`, `0h`, `0s`, an empty value: no minimum release age. The CLI prints `0` since 0.12.1 and `0h` before.
        public static func isZeroAge(_ value: String) -> Bool {
            let digits = value.filter(\.isNumber)
            return digits.isEmpty || digits.allSatisfy { $0 == "0" }
        }

        /// What the CLI prints as `from` for a key the user's config enforces (`src/policy.rs` `ENFORCED`).
        public static let enforcedOrigin = "config.toml, enforced"

        public let key: String
        public let value: String
        /// Where the value came from, as the CLI prints it: `skills.toml`, `config.toml`, `config.toml, enforced`,
        /// `env`, `default`.
        public let from: String

        public var id: String {
            key
        }

        public var kind: Kind {
            Kind(key: key)
        }

        /// The `allow-sources` list, whose value the Overview draws in mono.
        public var isAllowedSources: Bool {
            kind == .allowSources
        }

        /// Set by the organisation's `config.toml` and not overridable by the project (`ENFORCED` in policy.rs).
        public var isEnforced: Bool {
            from == Self.enforcedOrigin
        }

        /// The file or layer the value was set in, without the enforcement note: `config.toml`.
        public var origin: String {
            isEnforced ? String(from.prefix { $0 != "," }) : from
        }
    }

    public struct Doctor: Hashable, Sendable {
        public let ok: Bool
        public let passed: [String]
        public let problems: [String]
        public let fixed: [String]
        public let warnings: [String]
    }

    public let entries: [SkillEntry]
    public let attention: Attention
    public let policy: [PolicyRow]
    public let targets: StatusDocument.Targets?
    public let repositories: [StatusDocument.Repository]
    public let doctor: Doctor?
    /// Packages `outdated` lists as behind their constraint's newest; nil until updates were checked.
    public let updates: [Update]?
    public let checkedAt: Date

    public init(
        status: StatusDocument, audit: AuditDocument?, doctor: DoctorDocument?, outdated: OutdatedDocument?,
        checkedAt: Date = Date()
    ) {
        // A fresh `status` that shows the version `outdated` offered means the update was applied since the check:
        // the row is current without waiting for the next network check (`Update.settled(installed:)`).
        let installed = Dictionary(
            status.entries.compactMap { entry in entry.package.map { ($0, entry.version) } },
            uniquingKeysWith: { first, _ in first })
        let updates = outdated.map {
            Dictionary(
                $0.packages.map { ($0.package, Update($0).settled(installed: installed[$0.package] ?? nil)) },
                uniquingKeysWith: { first, _ in first })
        }
        let audited = Dictionary((audit?.skills ?? []).map { ($0.skill, $0) }, uniquingKeysWith: { first, _ in first })
        entries = status.entries.map { entry in
            let state = SkillState(cliState: entry.state)
            let kind = HealthMapping.kind(of: entry)
            let name = entry.skill ?? entry.package ?? entry.state
            let skill = entry.skill.flatMap { audited[$0] }
            let findings = skill?.findings ?? []
            let update = entry.package.flatMap { updates?[$0] }
            return SkillEntry(
                id: name, name: name, kind: kind, source: entry.source, version: entry.version, state: state,
                health: HealthMapping.health(state: state, update: update, findings: findings), update: update,
                findings: findings, path: skill?.path, description: entry.description, reach: skill.map(Reach.init),
                via: entry.via)
        }
        attention = Attention(entries)
        policy = status.policy.keys.sorted { PolicyRow.Kind.precedes($0, $1) }
            .map {
                PolicyRow(key: $0, value: status.policy[$0]?.value.shown ?? "", from: status.policy[$0]?.from ?? "")
            }
        targets = status.targets
        repositories = status.repositories
        self.doctor = doctor.map {
            Doctor(ok: $0.ok, passed: $0.passed, problems: $0.problems, fixed: $0.fixed, warnings: $0.warnings)
        }
        self.updates = updates.map { Array($0.values).sorted { $0.package < $1.package } }
        self.checkedAt = checkedAt
    }

    public var updatesChecked: Bool {
        updates != nil
    }

    /// Updates `update` would apply, one per package.
    public var availableUpdates: [Update] {
        (updates ?? []).filter { $0.available != nil }
    }

    public func entry(id: SkillEntry.ID?) -> SkillEntry? {
        id.flatMap { id in entries.first { $0.id == id } }
    }
}
