/// The text of `skillcask diff`, parsed for the review sheet: a title per package, then `--- a/` `+++ b/` file
/// pairs with mode lines, hunks, or a note that the file is binary or too large (`src/commands.rs`
/// `print_file_diff`). Lines are already escaped by the CLI (D26).
public struct UnifiedDiff: Hashable, Sendable {
    public struct File: Hashable, Sendable, Identifiable {
        public enum Change: Hashable, Sendable {
            case added
            case removed
            case modified
            case modeOnly
            case binary
            case tooLarge
        }

        public let path: String
        public let change: Change
        /// Every line after the headers: `@@`, `+`, `-` and context, in order.
        public let lines: [String]

        public var id: String {
            path
        }
    }

    public struct Package: Hashable, Sendable, Identifiable {
        public let name: String
        public let from: String?
        public let to: String
        public let files: [File]

        public var id: String {
            name
        }
    }

    public let packages: [Package]
    /// The CLI said `no newer versions within the constraints`.
    public let upToDate: Bool

    public init(text: String) {
        var packages: [Package] = []
        var current: (name: String, from: String?, to: String)?
        var files: [File] = []
        var file: (path: String, old: Bool, new: Bool, mode: Bool, lines: [String])?
        upToDate = text.contains("no newer versions within the constraints")

        func closeFile() {
            guard let open = file else { return }
            files.append(File(path: open.path, change: Self.change(of: open), lines: open.lines))
            file = nil
        }
        func closePackage() {
            closeFile()
            if let open = current {
                packages.append(Package(name: open.name, from: open.from, to: open.to, files: files))
            }
            files = []
            current = nil
        }

        // Lines the open hunk's `@@` header still counts: a removed `-- x` prints as `--- x`, not a file header.
        var left = (old: 0, new: 0)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if file != nil, left.old > 0 || left.new > 0, line.isEmpty || "+- ".contains(line.first ?? " ") {
                file?.lines.append(line)
                if !line.hasPrefix("+") { left.old -= 1 }
                if !line.hasPrefix("-") { left.new -= 1 }
            } else if file != nil, line.hasPrefix("@@") {
                let header = File.hunkHeader(line)
                left = (header.oldCount, header.newCount)
                file?.lines.append(line)
            } else if line.hasPrefix("--- ") {
                closeFile()
                let old = line != "--- /dev/null"
                file = (old ? String(line.dropFirst(6)) : "", old, false, false, [])
            } else if line.hasPrefix("+++ "), var open = file {
                if line != "+++ /dev/null" {
                    open.path = String(line.dropFirst(6))
                    open.new = true
                }
                file = open
            } else if file != nil, line.hasPrefix("old mode ") || line.hasPrefix("new mode ") {
                file?.mode = true
            } else if file != nil,
                line.hasPrefix("@@") || line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ")
                    || line == "Binary files differ" || line == "Files differ (too large to show)"
            {
                file?.lines.append(line)
            } else if let title = Self.title(line) {
                closePackage()
                current = title
            } else if line.isEmpty, file != nil {
                file?.lines.append(line)
            }
        }
        closePackage()
        self.packages = packages
    }

    /// `acme/one 1.0.0 -> 1.1.0` or `acme/one 1.1.0 (new)`.
    static func title(_ line: String) -> (name: String, from: String?, to: String)? {
        let words = line.split(separator: " ").map(String.init)
        guard let name = words.first, name.contains("/") else { return nil }
        if words.count == 4, words[2] == "->" {
            return (name, words[1], words[3])
        }
        if words.count == 3, words[2] == "(new)" {
            return (name, nil, words[1])
        }
        return nil
    }

    private static func change(
        of file: (path: String, old: Bool, new: Bool, mode: Bool, lines: [String])
    ) -> File.Change {
        if file.lines.contains("Binary files differ") { return .binary }
        if file.lines.contains("Files differ (too large to show)") { return .tooLarge }
        if !file.old { return .added }
        if !file.new { return .removed }
        return file.lines.isEmpty && file.mode ? .modeOnly : .modified
    }
}
