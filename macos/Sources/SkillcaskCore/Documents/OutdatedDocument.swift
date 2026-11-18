/// `outdated --json` (D32): per manifest package, the locked version, the newest within the constraint and the
/// newest overall. Needs the network. Exit 1 only with `--strict`, which the app never passes.
public struct OutdatedDocument: Decodable, Hashable, Sendable {
    public struct Package: Decodable, Hashable, Sendable {
        public let package: String
        public let locked: String?
        /// The newest version the constraint allows, the minimum release age not applied (`registry::newest`): equal
        /// to `locked` when nothing is newer within the constraint, and possibly a version `update` would not lock
        /// yet (`note` then names it).
        public let within: String?
        public let latest: String?
        /// Free text such as `v4.3.0 eligible 2026-10-26T21:44:27Z` when a newer version waits for the cooldown.
        public let note: String?
        /// Since D67: the RFC 3339 instant the cooldown on `within` ends; nil when nothing waits or from an older CLI.
        public let eligible: String?
        /// Never printed by a released CLI: an earlier plan's time of `latest`, kept decoded for design fixtures
        /// written to it. D67 prints `latest-released` instead; read that first.
        public let released: String?
        /// Since D67: when `locked` was released, from skills.lock (RFC 3339); nil when not known or from an older CLI.
        public let lockedReleased: String?
        /// Since D67: when `within` was released; nil for GitHub and git sources, when not known or from an older CLI.
        public let withinReleased: String?
        /// Since D67: when `latest` was released; nil for GitHub and git sources, when not known or from an older CLI.
        public let latestReleased: String?

        enum CodingKeys: String, CodingKey {
            case package
            case locked
            case within
            case latest
            case note
            case eligible
            case released
            case lockedReleased = "locked-released"
            case withinReleased = "within-released"
            case latestReleased = "latest-released"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            package = try c.decode(String.self, forKey: .package)
            locked = try c.decodeIfPresent(String.self, forKey: .locked)
            within = try c.decodeIfPresent(String.self, forKey: .within)
            latest = try c.decodeIfPresent(String.self, forKey: .latest)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            eligible = try c.decodeIfPresent(String.self, forKey: .eligible)
            released = try c.decodeIfPresent(String.self, forKey: .released)
            // Tolerant: a release time of another shape is "not known" and never fails the document.
            lockedReleased = try? c.decodeIfPresent(String.self, forKey: .lockedReleased)
            withinReleased = try? c.decodeIfPresent(String.self, forKey: .withinReleased)
            latestReleased = try? c.decodeIfPresent(String.self, forKey: .latestReleased)
        }
    }

    public let packages: [Package]
    /// Packages whose locked version is behind their constraint's newest, by name.
    public let behind: [String]
}
