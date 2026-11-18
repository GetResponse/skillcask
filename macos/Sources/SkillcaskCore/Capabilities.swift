/// What the located CLI can do, derived from its version. Everything the app needs beyond `minimum` is a
/// `Feature` it checks before use, so one app binary works with every supported CLI release.
public struct Capabilities: Hashable, Sendable {
    /// Additions to the CLI that the app uses when present and works around when absent.
    public enum Feature: String, CaseIterable, Hashable, Sendable {
        /// `init`, `install`, `update`, `add` and `remove` print one JSON document with `--json`.
        case jsonMutations
        /// `status --json` entries carry `description`.
        case statusDescription
        /// `outdated --json` packages carry `eligible` (RFC 3339) instead of a free-text `note`.
        case outdatedEligible
        /// `status --json` entries carry `source`: the repository name (`packagist`, `github`, a custom name) or
        /// `git` for a git URL. Planned, not shipped: the list row's second line and the detail pill need it.
        case statusSource
        /// An earlier plan's `released` key on `outdated --json` packages (when `latest` was published); never
        /// shipped. D67 prints `locked-released`, `within-released`, `latest-released`, `info`'s
        /// `versions-released` and `status`'s `released` instead, which the app reads by key presence, ungated:
        /// absent from an older CLI, so the Versions tab says "unknown" as before.
        case outdatedReleased
        /// Planned: `audit --json` also lists not-managed skills with `kind: "not managed"`. At 0.9.4 `audit`
        /// builds its rows from the lock, the hand-written and the project skills only, so a not-managed skill
        /// has no findings and no reach until this ships.
        case auditNotManaged
        /// `info --json <skill>` carries `description`.
        case infoSkillDescription
        /// `add --rename old=new`.
        case addRename
        /// `add --skill name` (repeatable).
        case addSkill
        /// `diff --json`.
        case diffJSON
        /// `self-check --json` (D51). Gated, not just tried: 0.9.0–0.10.1 take an unknown command for a plugin and
        /// run `skillcask-<name>` from `PATH` (`src/main.rs` `plugin`), so asking them would start whatever
        /// `skillcask-self-check` lies there. `SelfCheckGate` also lets the bundled CLI through.
        case selfCheck
    }

    /// The oldest CLI the app drives: 0.9.4 has every `--json` document the app reads (D32, D40–D42), `status
    /// --json` keeps `package` a bare name with the requirers in `via`, and `config` reads and writes settings
    /// (D48).
    public static let minimum = Version(0, 9, 4)

    /// The release that shipped each feature beyond `minimum`. A feature that is only planned has no entry, so it
    /// stays off.
    static let shipped: [Feature: Version] = [.selfCheck: Version(0, 10, 2)]

    public let version: Version
    public let features: Set<Feature>

    /// The features a CLI of `version` is known to have.
    public init(version: Version) {
        self.init(
            version: version, features: Set(Feature.allCases.filter { Self.shipped[$0].map { version >= $0 } ?? false })
        )
    }

    /// An explicit feature set, for tests and for fixtures of a release that does not exist yet.
    public init(version: Version, features: Set<Feature>) {
        self.version = version
        self.features = features
    }

    public func supports(_ feature: Feature) -> Bool {
        features.contains(feature)
    }

    public var isTooOld: Bool {
        version < Self.minimum
    }
}
