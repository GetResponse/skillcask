import Foundation

/// `config --json -- <key>` (D48, 0.9.4): one setting's effective value and the layer it came from. Both are
/// `null` (and the CLI exits 1) when nothing sets the key.
public struct ConfigValueDocument: Decodable, Hashable, Sendable {
    /// `true`/`false`, a string, a number or a list, as the key has it; `.null` when not set.
    public let value: JSONValue
    /// `config.toml`, `config.toml, enforced`, `system config.toml`, `system config.toml, enforced` (D60),
    /// `skills.toml`, `environment` or `default`; nil when not set.
    public let from: String?

    enum CodingKeys: String, CodingKey {
        case value
        case from
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        from = try c.decodeIfPresent(String.self, forKey: .from)
    }
}

extension ConfigValueDocument {
    /// `from` as a layer; nil when nothing sets the key.
    public var layer: ConfigLayer? {
        from.map(ConfigLayer.init)
    }

    /// For the decoder of `ConfigListDocument`'s tests and previews.
    public init(value: JSONValue, from: String?) {
        self.value = value
        self.from = from
    }
}

/// `config --json` without a key (D48, 0.9.4): the file `config` reads and writes, and every key with its effective
/// value and layer. With `-g` those are the keys of config.toml as an empty project would see them. `value` and
/// `from` are both `null` for a key nothing sets; a list's URLs are redacted (`src/commands.rs` `policy_value`).
public struct ConfigListDocument: Decodable, Hashable, Sendable {
    public let file: String
    public let settings: [String: ConfigValueDocument]

    public init(file: String, settings: [String: ConfigValueDocument]) {
        self.file = file
        self.settings = settings
    }

    /// The keys in `ConfigKey.order`, then any key a newer CLI adds, by name (the CLI prints them sorted).
    public var orderedKeys: [String] {
        let known = ConfigKey.order.filter { settings[$0] != nil }
        return known + settings.keys.filter { !ConfigKey.order.contains($0) }.sorted()
    }
}

/// The layer a setting came from, as `config` names it (`src/policy.rs` `resolve`, `src/config.rs` `settings`).
public enum ConfigLayer: Hashable, Sendable {
    /// `config.toml`.
    case configFile
    /// `config.toml, enforced`: listed in `policy.enforce`, so no project can loosen it.
    case enforced
    /// `system config.toml` (D60): the machine-wide file; the user's config.toml may set the key over it.
    case system
    /// `system config.toml, enforced`: the organisation enforces it; the user's config.toml may only tighten it.
    case systemEnforced
    /// A `SKILLCASK_*` variable of the CLI's environment: it wins over every file.
    case environment
    /// The built-in value.
    case builtIn
    /// `skills.toml` (only without `-g`).
    case manifest
    /// A layer a newer CLI names.
    case other(String)

    public init(_ from: String) {
        switch from {
        case "config.toml": self = .configFile
        case "config.toml, enforced": self = .enforced
        case "system config.toml": self = .system
        case "system config.toml, enforced": self = .systemEnforced
        case "environment": self = .environment
        case "default": self = .builtIn
        case "skills.toml": self = .manifest
        default: self = .other(from)
        }
    }

    /// The user's config.toml sets the key, so `config --unset` has something to remove.
    public var isConfigFile: Bool {
        self == .configFile || self == .enforced
    }
}

/// What the app knows of `config`'s keys (D48, 0.9.4, `src/config.rs` and `src/policy.rs`).
public enum ConfigKey {
    /// The CLI's own order: `policy::KEYS`, then the keys `settings` appends.
    public static let order = [
        "policy.min-release-age", "policy.allow-ranges", "policy.packagist", "policy.github-requires",
        "policy.allow-sources", "policy.deny-patterns", "policy.deny-packages", "policy.enforce", "agents.targets",
        "search.skills-sh",
    ]

    /// How a value is edited and written.
    public enum Kind: Hashable, Sendable {
        /// `true` or `false`.
        case bool
        /// One argument per entry (`config.rs` `LISTS`).
        case list
        /// One string, such as `3d`.
        case text
    }

    static let bools: Set<String> = [
        "policy.allow-ranges", "policy.packagist", "policy.github-requires", "policy.deny-patterns",
        "search.skills-sh",
    ]
    static let lists: Set<String> = [
        "policy.allow-sources", "policy.deny-packages", "policy.enforce", "agents.targets",
    ]

    /// A known key's kind; a key a newer CLI adds is judged by its value.
    public static func kind(of key: String, value: JSONValue) -> Kind {
        if bools.contains(key) {
            return .bool
        }
        if lists.contains(key) {
            return .list
        }
        switch value {
        case .bool: return .bool
        case .array: return .list
        default: return .text
        }
    }

    /// `allow-sources` takes `https://` prefixes, which may carry a user name and token (`policy.rs` redacts them
    /// in `Display`, `config --json` prints them redacted): never shown or logged as typed.
    public static func mayHoldCredentials(_ key: String) -> Bool {
        key == "policy.allow-sources"
    }

    /// The variable that overrides a `policy.*` key (`policy::env_layer`): `SKILLCASK_MIN_RELEASE_AGE`; nil for
    /// the keys no variable sets.
    public static func environmentVariable(for key: String) -> String? {
        let policyKeys = order.prefix { $0 != "policy.enforce" }
        guard policyKeys.contains(key), let name = key.split(separator: ".").last else { return nil }
        return "SKILLCASK_" + name.uppercased().replacingOccurrences(of: "-", with: "_")
    }
}

/// URLs as the CLI prints them (`src/http.rs` `redact`): without user name and password, and with `…` for a query
/// (percent-encoded, `?%E2%80%A6`, as `config --json` prints it).
public enum Redaction {
    public static func url(_ text: String) -> String {
        guard var parts = URLComponents(string: text), parts.scheme != nil, parts.host != nil else { return text }
        guard parts.user != nil || parts.password != nil || parts.query != nil else { return text }
        parts.user = nil
        parts.password = nil
        if parts.query != nil {
            parts.query = "…"
        }
        return parts.string ?? text
    }

    /// What replaces a user name and password: `https://••••@host`.
    public static let maskedUser = "••••"

    /// `text` with every `scheme://user[:password]@` and `user[:password]@host` masked as `••••@`, the query of
    /// each typed value as `…`, and each typed value also as the CLI quotes it in a message (Rust `{:?}`: `\"`
    /// and `\\` escaped). Used where the CLI or the app could show what was typed for a credential-bearing key.
    public static func credentials(in text: String, typed: [String] = []) -> String {
        var out = text
        for value in typed {
            let safe = masked(value)
            guard safe != value else { continue }
            let quoted = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            out = out.replacingOccurrences(of: quoted, with: safe).replacingOccurrences(of: value, with: safe)
        }
        return userInfo(in: out)
    }

    /// One value with its user name, password and query masked.
    static func masked(_ value: String) -> String {
        var value = userInfo(in: value)
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query]) + "?…"
        }
        return value
    }

    /// `scheme://user:pw@` → `scheme://••••@`; `user:pw@host` → `••••@host`. The user part ends at whitespace, `/`,
    /// a quote or a backslash, so a path or the rest of a sentence is kept.
    static func userInfo(in text: String) -> String {
        let pattern = #"((?:[A-Za-z][A-Za-z0-9+.\-]*://)?)[^\s/@"\\]+@(?=[^\s@])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1\(maskedUser)@")
    }
}
