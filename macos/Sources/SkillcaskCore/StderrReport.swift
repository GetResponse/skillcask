/// What the CLI said on stderr, split by the prefixes `src/ui.rs` prints: `error: `, `  hint: `, `warning: `,
/// `note: `. Lines without a prefix (progress, verbose HTTP) land in `other`.
public struct StderrReport: Hashable, Sendable {
    public var error: String?
    public var hint: String?
    public var warnings: [String] = []
    public var notes: [String] = []
    public var other: [String] = []

    public init(
        error: String? = nil, hint: String? = nil, warnings: [String] = [], notes: [String] = [], other: [String] = []
    ) {
        self.error = error
        self.hint = hint
        self.warnings = warnings
        self.notes = notes
        self.other = other
    }

    /// The first `error:` line wins; a later one is kept in `other` so nothing is lost. A message's own line
    /// breaks print as lines indented by two spaces (`required by: …`), which stay part of the error.
    public init(parsing stderr: String) {
        var inError = false
        for raw in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Self.stripANSI(String(raw))
            if line.isEmpty { continue }
            let continues = inError && line.hasPrefix("  ") && !line.hasPrefix("  hint: ")
            inError = continues || (error == nil && line.hasPrefix("error: "))
            if continues, let first = error {
                error = first + "\n" + line.dropFirst(2)
            } else if let text = Self.strip("error: ", from: line), error == nil {
                error = text
            } else if let text = Self.strip("  hint: ", from: line), hint == nil {
                hint = text
            } else if let text = Self.strip("warning: ", from: line) {
                warnings.append(text)
            } else if let text = Self.strip("note: ", from: line) {
                notes.append(text)
            } else {
                other.append(line)
            }
        }
    }

    private static func strip(_ prefix: String, from line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// The app always runs the CLI with `NO_COLOR=1`; this is a belt for a user-configured wrapper script.
    private static func stripANSI(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var out = ""
        var rest = Substring(line)
        while let esc = rest.firstIndex(of: "\u{1B}") {
            out += rest[..<esc]
            rest = rest[rest.index(after: esc)...]
            guard rest.first == "[" else { continue }
            rest = rest.dropFirst()
            while let c = rest.first, c.isNumber || c == ";" {
                rest = rest.dropFirst()
            }
            rest = rest.dropFirst()
        }
        return out + rest
    }
}
