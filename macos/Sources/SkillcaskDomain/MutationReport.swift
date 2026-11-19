/// What a mutation changed, for the outcome toast and the post-mutation selection. From the verb lines the CLI
/// prints (`src/ui.rs` `done`): `added`, `installed`, `updated a -> b`, `locked`, `removed`, `kept … as a
/// dependency`, `adopted`, `created`.
public struct MutationReport: Hashable, Sendable {
    public struct Updated: Hashable, Sendable {
        public let package: String
        public let from: String
        public let to: String
    }

    public var added: [String] = []
    /// The version `add` resolved for the package it added, from its own line `added <pkg> = "<constraint>"
    /// (<version>)` (`src/commands.rs` `finish_add`); a dependency's `added <pkg> <version> (dependency of …)` is
    /// not in here. Keyed by package, the version as the CLI printed it.
    public var addedVersions: [String: String] = [:]
    public var installed: [String] = []
    public var updated: [Updated] = []
    public var locked: [String] = []
    public var removed: [String] = []
    public var kept: [String] = []
    public var adopted: [String] = []
    public var created: [String] = []
    public var warnings: [String] = []

    public init() {}

    /// `stdout` lines of a mutation; `stderr` warnings come from the `StderrReport`.
    public init(verbLines stdout: String, warnings: [String] = []) {
        self.warnings = warnings
        for raw in stdout.split(separator: "\n") {
            let line = String(raw)
            guard let space = line.firstIndex(of: " ") else { continue }
            let rest = String(line[line.index(after: space)...])
            switch line[..<space] {
            case "added":
                added.append(Self.firstWord(rest))
                if let version = Self.addedVersion(rest) {
                    addedVersions[Self.firstWord(rest)] = version
                }
            case "installed": installed.append(Self.firstWord(rest))
            case "updated":
                if let updated = Self.updatedLine(rest) {
                    self.updated.append(updated)
                }
            case "locked": locked.append(Self.firstWord(rest))
            case "removed": removed.append(Self.firstWord(rest))
            case "kept": kept.append(Self.firstWord(rest))
            case "adopted": adopted.append(Self.firstWord(rest))
            case "created": created.append(rest)
            default: break
            }
        }
    }

    public var isEmpty: Bool {
        added.isEmpty && installed.isEmpty && updated.isEmpty && locked.isEmpty && removed.isEmpty && kept.isEmpty
            && adopted.isEmpty && created.isEmpty
    }

    /// `acme/one 1.0.0 -> 1.1.0`.
    static func updatedLine(_ text: String) -> Updated? {
        let words = text.split(separator: " ").map(String.init)
        guard words.count == 4, words[2] == "->" else { return nil }
        return Updated(package: words[0], from: words[1], to: words[3])
    }

    /// `<pkg> = "<constraint>" (<version>)` → `<version>`; nil for any other shape.
    static func addedVersion(_ text: String) -> String? {
        guard text.contains(" = \""), text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let version = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !version.isEmpty, !version.contains(" ") else { return nil }
        return String(version)
    }

    /// The skill a line `adopted <shown path> (moved to <dest>)` moved aside: the last component of the path
    /// (`~/.claude/skills/caveman` → `caveman`), as the CLI moves `<target>/<skill>` and `.agents/skills/<skill>`
    /// (`src/commands.rs` `adopt`).
    public var adoptedSkills: Set<String> {
        Set(adopted.compactMap { $0.split(separator: "/").last.map(String.init) })
    }

    static func firstWord(_ text: String) -> String {
        String(text.prefix { !$0.isWhitespace && $0 != ":" })
    }
}
