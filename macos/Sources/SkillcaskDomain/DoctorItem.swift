import Foundation

/// One line of `doctor --json` (`passed`, `problems`, `fixed` or `warnings`), typed, so no view compares or
/// splits a CLI sentence. The shapes are the ones `src/commands.rs` `doctor` and `shadows` print; a line a newer
/// CLI adds survives as `.other` and is shown as printed.
public enum DoctorItem: Hashable, Sendable {
    /// How a link in an agent directory differs from the plan (`project::LinkState`, lowercased).
    public enum LinkProblem: Hashable, Sendable {
        /// `link missing`: the agent directory has no entry for the skill.
        case missing
        /// `link wrong`: a symlink pointing elsewhere, or a stale copy.
        case wrong
        /// `link foreign`: a real file or folder skillcask did not create.
        case foreign
        case other(String)

        public init(word: String) {
            switch word {
            case "missing": self = .missing
            case "wrong": self = .wrong
            case "foreign": self = .foreign
            default: self = .other(word)
            }
        }
    }

    /// What fixes a problem: `doctor --fix` (links, the git index, the ignore block) or `install` (a download).
    public enum Remedy: Hashable, Sendable {
        case repair
        case sync
    }

    // MARK: - Problems and fixed items

    /// `.cursor/skills/pdf: link wrong`.
    case link(path: String, problem: LinkProblem)
    /// `.claude/skills/x exists and was not created by skillcask; move it away`.
    case notOurs(path: String)
    /// `links in directories that are no longer targets: a, b`.
    case strayLinks([String])
    /// `managed paths committed to git: a, b`.
    case committed([String])
    /// `.gitignore: stale managed block`.
    case staleBlock(file: String)
    /// `.skillcask/skills/jira-syntax: not installed (netresearch/agent-jira-skill); run …`.
    case notInstalled(skill: String, package: String?)
    /// `.skillcask/skills/x: modified (acme/x); run …`.
    case modified(skill: String, package: String?)

    // MARK: - Warnings

    /// `x: ~/.claude/skills/x shadows the project skill in Claude Code`.
    case shadowed(skill: String, path: String)
    /// `x: ~/.cursor/skills/x also exists; the agent may show both`.
    case alsoInstalled(skill: String, path: String)

    // MARK: - Passed

    /// `links: 26 ok`.
    case linksOk(Int)
    /// `targets: no links left in former target directories`.
    case noStrayLinks
    /// `git index: no managed paths committed`.
    case gitIndexClean
    /// `.gitignore: managed block up to date`.
    case blockUpToDate(file: String)
    /// `installed: 3 skill(s) match skills.lock`.
    case installedMatch(Int)

    case other(String)

    // MARK: - Parsing

    public init(line: String) {
        if let item = Self.whole(line) {
            self = item
        } else if let range = line.range(of: ": ") {
            let head = String(line[..<range.lowerBound])
            let rest = String(line[range.upperBound...])
            self = Self.headed(head, rest) ?? .other(line)
        } else {
            self = .other(line)
        }
    }

    /// Lines recognised as a whole or by a fixed prefix.
    private static func whole(_ line: String) -> DoctorItem? {
        let notOurs = " exists and was not created by skillcask; move it away"
        let stray = "links in directories that are no longer targets: "
        let committed = "managed paths committed to git: "
        if line.hasSuffix(notOurs) {
            return .notOurs(path: String(line.dropLast(notOurs.count)))
        }
        if line.hasPrefix(stray) {
            return .strayLinks(list(line.dropFirst(stray.count)))
        }
        if line.hasPrefix(committed) {
            return .committed(list(line.dropFirst(committed.count)))
        }
        if line == "targets: no links left in former target directories" {
            return .noStrayLinks
        }
        if line == "git index: no managed paths committed" {
            return .gitIndexClean
        }
        if let count = number(in: line, prefix: "links: ", suffix: " ok") {
            return .linksOk(count)
        }
        if let count = number(in: line, prefix: "installed: ", suffix: " skill(s) match skills.lock") {
            return .installedMatch(count)
        }
        return nil
    }

    /// `<path or name>: <what>` lines.
    private static func headed(_ head: String, _ rest: String) -> DoctorItem? {
        if rest == "stale managed block" {
            return .staleBlock(file: head)
        }
        if rest == "managed block up to date" {
            return .blockUpToDate(file: head)
        }
        if rest.hasPrefix("link ") {
            return .link(path: head, problem: LinkProblem(word: String(rest.dropFirst("link ".count))))
        }
        if rest.hasPrefix("not installed") {
            return .notInstalled(skill: lastComponent(head), package: parenthesised(rest))
        }
        if rest.hasPrefix("modified") {
            return .modified(skill: lastComponent(head), package: parenthesised(rest))
        }
        if let range = rest.range(of: " shadows the project skill") {
            return .shadowed(skill: head, path: String(rest[..<range.lowerBound]))
        }
        if let range = rest.range(of: " also exists") {
            return .alsoInstalled(skill: head, path: String(rest[..<range.lowerBound]))
        }
        return nil
    }

    private static func list(_ text: Substring) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func number(in line: String, prefix: String, suffix: String) -> Int? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else {
            return nil
        }
        return Int(line.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// `netresearch/agent-jira-skill` out of `not installed (netresearch/agent-jira-skill); run …`.
    private static func parenthesised(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    // MARK: - Derived

    /// What fixes this item when it is a problem or a warning; nil when neither command does (a foreign file the
    /// user must move, a shadowing copy in the home folder).
    public var remedy: Remedy? {
        switch self {
        case .link(_, let problem): problem == .foreign ? nil : .repair
        case .strayLinks, .committed, .staleBlock: .repair
        case .notInstalled, .modified: .sync
        default: nil
        }
    }

    /// A path of a `doctor` line relative to the scope root: the global scope prints `~/.claude/skills/x`
    /// (`Scope::show`), a project `.claude/skills/x`, which is kept as printed.
    public static func scopeRelative(_ path: String, isGlobal: Bool) -> String {
        isGlobal && path.hasPrefix("~/") ? String(path.dropFirst(2)) : path
    }
}

extension ScopeSnapshot.Doctor {
    /// `problems`, typed.
    public var problemItems: [DoctorItem] { problems.map(DoctorItem.init(line:)) }
    /// `warnings`, typed.
    public var warningItems: [DoctorItem] { warnings.map(DoctorItem.init(line:)) }
    /// `fixed`, typed.
    public var fixedItems: [DoctorItem] { fixed.map(DoctorItem.init(line:)) }
    /// `passed`, typed.
    public var passedItems: [DoctorItem] { passed.map(DoctorItem.init(line:)) }

    /// The skills `doctor` reports as not installed (`.skillcask/skills/<name>: not installed …`).
    public var missingSkills: Set<String> {
        Set(
            problemItems.compactMap { item in
                if case .notInstalled(let skill, _) = item { skill } else { nil }
            })
    }

    /// What fixes `item` in this answer. `doctor --fix` relinks only when the skill's folder exists
    /// (`src/commands.rs` `doctor`: `s.root.join(source).join(&n).is_dir()`), so a link to a skill that is not
    /// installed stays open after Repair: Sync installs the skill and links it. Every other item: `item.remedy`.
    public func remedy(of item: DoctorItem) -> DoctorItem.Remedy? {
        if case .link(let path, let problem) = item, problem != .foreign,
            let name = path.split(separator: "/").last, missingSkills.contains(String(name))
        {
            return .sync
        }
        return item.remedy
    }

    /// Repair (`doctor --fix`) has something to do: an open problem or warning it fixes (Health-States: after
    /// Repair, with only a download left, the button is disabled).
    public var canRepair: Bool {
        (problemItems + warningItems).contains { remedy(of: $0) == .repair }
    }
}
