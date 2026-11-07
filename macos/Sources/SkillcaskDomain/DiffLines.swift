/// One row of a file's diff as the review sheet draws it: the kind decides the colour and the marker, the two
/// numbers fill the gutter (`oldNumber` for context and removed lines, `newNumber` for context and added lines,
/// neither for a hunk header or a note), `text` is the line without its `+`/`-`/space prefix. `id` is the row's
/// position in the file, so a file's rows stay distinct even when two lines read the same.
public struct DiffLine: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// An unchanged line, present in both versions.
        case context
        /// A line only in the new version.
        case added
        /// A line only in the old version.
        case removed
        /// `@@ -a,b +c,d @@ heading`: `text` is the whole header.
        case hunk
        /// The CLI's own words instead of content: `Binary files differ`, `Files differ (too large to show)`.
        case note
    }

    public let id: Int
    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public init(id: Int, kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

extension UnifiedDiff.File {
    /// `lines` numbered: every `@@` header seeds the old and new counters, context lines advance both, `+` the
    /// new one, `-` the old one. The CLI prints a blank context line as one space; an empty line (that space
    /// trimmed on the way) counts as context while the hunk still has lines to show, and draws nothing after
    /// it. A `\ No newline at end of file` never reaches
    /// `lines` (`UnifiedDiff` drops it).
    public var diffLines: [DiffLine] {
        var rows: [DiffLine] = []
        var old = 0
        var new = 0
        var oldRemaining = 0
        var newRemaining = 0
        for line in lines {
            let id = rows.count
            if line.hasPrefix("@@") {
                let header = Self.hunkHeader(line)
                old = header.old
                new = header.new
                oldRemaining = header.oldCount
                newRemaining = header.newCount
                rows.append(DiffLine(id: id, kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
            } else if line == "Binary files differ" || line == "Files differ (too large to show)" {
                rows.append(DiffLine(id: id, kind: .note, oldNumber: nil, newNumber: nil, text: line))
            } else if line.hasPrefix("+") {
                rows.append(
                    DiffLine(id: id, kind: .added, oldNumber: nil, newNumber: new, text: String(line.dropFirst())))
                new += 1
                newRemaining -= 1
            } else if line.hasPrefix("-") {
                rows.append(
                    DiffLine(id: id, kind: .removed, oldNumber: old, newNumber: nil, text: String(line.dropFirst())))
                old += 1
                oldRemaining -= 1
            } else if line.hasPrefix(" ") || (line.isEmpty && (oldRemaining > 0 || newRemaining > 0)) {
                rows.append(
                    DiffLine(
                        id: id, kind: .context, oldNumber: old, newNumber: new, text: String(line.dropFirst())))
                old += 1
                new += 1
                oldRemaining -= 1
                newRemaining -= 1
            }
        }
        return rows
    }

    /// The path as the review sheet's file list and strip write it: without the leading skill directory the CLI
    /// prints (`pdf/scripts/ocr.py` → `scripts/ocr.py`, `pdf/SKILL.md` → `SKILL.md`). A path with one component
    /// is returned whole.
    public var pathInSkill: String {
        guard let slash = path.firstIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// The number of `+` lines.
    public var additions: Int {
        lines.filter { $0.hasPrefix("+") }.count
    }

    /// The number of `-` lines.
    public var deletions: Int {
        lines.filter { $0.hasPrefix("-") }.count
    }

    /// `@@ -8,11 +8,16 @@ Reading` → old 8 for 11 lines, new 8 for 16; a missing count means one line
    /// (`@@ -0,0 +1 @@`), and a header that does not parse starts both sides at 1 with no lines expected.
    static func hunkHeader(_ line: String) -> (old: Int, oldCount: Int, new: Int, newCount: Int) {
        let words = line.split(separator: " ")
        guard words.count >= 3, words[1].hasPrefix("-"), words[2].hasPrefix("+") else { return (1, 0, 1, 0) }
        let old = range(words[1].dropFirst())
        let new = range(words[2].dropFirst())
        return (old.start, old.count, new.start, new.count)
    }

    /// `8,11` → start 8, count 11; `1` → start 1, count 1.
    private static func range(_ text: Substring) -> (start: Int, count: Int) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let start = parts.first.flatMap { Int($0) } ?? 1
        let count = parts.count > 1 ? Int(parts[1]) ?? 0 : 1
        return (start, count)
    }
}
