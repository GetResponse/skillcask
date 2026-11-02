import SkillcaskCore

/// One `[agents] targets` entry of `status.targets` with the directory the CLI links into for it.
///
/// `targets.entries` (as written) and `targets.dirs` (resolved, deduplicated) are not parallel lists: an agent that
/// reads the shared store gets no directory (D29), and two entries naming one directory link once. The app pairs
/// them by the CLI's preset convention: a path entry (it holds a `/`) is its own directory, the presets with a
/// directory of their own (`ownDirectory`) take theirs (`resolve_targets` always lists it in `dirs`), and any other
/// entry reads the store. `macos/DESIGN.md` Q19 names the CLI key that would replace this.
public struct AgentTarget: Hashable, Sendable, Identifiable {
    /// The entry as written in `[agents] targets`: `claude`, `cursor`, `./tools/skills`.
    public let entry: String
    /// The directory relative to the scope root (`.claude/skills`), or nil when the agent reads the store.
    public let directory: String?
    /// The global scope: paths are under the home folder and shown with `~/`.
    public let isGlobal: Bool

    public init(entry: String, directory: String?, isGlobal: Bool = false) {
        self.entry = entry
        self.directory = directory
        self.isGlobal = isGlobal
    }

    /// Unique within a scope: `resolve` drops repeated entries.
    public var id: String {
        entry
    }

    /// A path entry rather than an agent name.
    public var isPath: Bool {
        entry.contains("/")
    }

    /// The store every skill is installed into (`src/project.rs` `STORE`, D29): the agents without a directory of
    /// their own read it directly.
    public static let store = ".agents/skills"

    /// The directory the agent reads skills from, relative to the scope root: its own, else the store.
    public var readsFrom: String {
        directory ?? Self.store
    }

    /// `readsFrom` as the user reads it: `~/.claude/skills` in the global scope (as the CLI prints it), else
    /// relative to the project.
    public var shownPath: String {
        isGlobal ? "~/\(readsFrom)" : readsFrom
    }

    /// The presets that get a link directory of their own (`PRESETS` in `src/manifest.rs`: `claude` and `kiro` in
    /// both scopes, `junie` in the global scope only); every other preset reads the store.
    public static func ownDirectory(of preset: String, isGlobal: Bool) -> String? {
        switch preset {
        case "claude": ".claude/skills"
        case "kiro": ".kiro/skills"
        case "junie": isGlobal ? ".junie/skills" : nil
        default: nil
        }
    }

    /// The agents shown first wherever a skill's agents are listed (row badges, the detail's lines, VoiceOver):
    /// the two most used, in this order. The one place this priority lives.
    public static let priority = ["claude", "codex"]

    /// `targets` in display order: `priority` first, then the other presets in `[agents] targets` order, then the
    /// path targets (a folder reads after the named agents), also in that order. The Overview's Agents card keeps
    /// the config order, since it mirrors `agents.targets`.
    public static func displayOrder(_ targets: [AgentTarget]) -> [AgentTarget] {
        let first = priority.compactMap { name in targets.first { $0.entry == name } }
        let presets = targets.filter { !$0.isPath && !priority.contains($0.entry) }
        return first + presets + targets.filter(\.isPath)
    }

    /// Every entry of `targets` paired with its directory, in the order written, a repeated entry once.
    public static func resolve(_ targets: StatusDocument.Targets?, isGlobal: Bool) -> [AgentTarget] {
        guard let targets else { return [] }
        var seen: Set<String> = []
        return targets.entries.compactMap { entry in
            guard seen.insert(entry).inserted else { return nil }
            let directory: String?
            if entry.contains("/") {
                var path = entry
                while path.hasSuffix("/") {
                    path.removeLast()
                }
                directory = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            } else {
                directory = ownDirectory(of: entry, isGlobal: isGlobal)
            }
            return AgentTarget(entry: entry, directory: directory, isGlobal: isGlobal)
        }
    }
}

/// Which agents of the scope see one skill, and which link is missing or wrong: the per-skill agent badges of the
/// skill row and the per-agent lines of the detail. Built by `AgentIndex` from `status` and `doctor`.
public struct AgentReach: Hashable, Sendable {
    /// What one agent sees of the skill.
    public enum State: Hashable, Sendable {
        /// The link (or, for a store agent, the installed folder) is in place.
        case linked
        /// `link missing`: the agent directory has no entry for the skill.
        case missing
        /// `link wrong`: a symlink pointing elsewhere, or a stale copy.
        case wrong
        /// A file or folder skillcask did not create holds the skill's name (`link foreign`, or `exists and was
        /// not created by skillcask`).
        case blocked
        /// A project skill's own link into the store (`.agents/skills/<name>` → `.skills/<name>`) is missing or
        /// wrong: no agent sees it, whatever its own link says (`doctor` then also calls every target link
        /// wrong; the store is the cause). Repair relinks it.
        case storeLinkBroken
        /// A file or folder skillcask did not create sits at the project skill's store path (`.agents/skills/<name>:
        /// link foreign`): no agent sees the skill, and Repair never touches it (`doctor --fix` skips foreign paths).
        case storeBlocked
        /// The skill itself is not installed, so no agent sees it.
        case notInstalled
        /// `doctor` has not answered yet (the first, status-only load).
        case pending
        /// `doctor` failed in the last refresh: the links could not be checked (an older answer is not trusted
        /// for skills it may not cover).
        case unknown

        /// The store is the one cause for every agent: said once, not counted per agent.
        public var isStoreProblem: Bool {
            self == .storeLinkBroken || self == .storeBlocked
        }

        /// A link problem the user can see on the row.
        public var isProblem: Bool {
            switch self {
            case .missing, .wrong, .blocked, .storeLinkBroken, .storeBlocked: true
            case .linked, .notInstalled, .pending, .unknown: false
            }
        }
    }

    public struct Link: Hashable, Sendable, Identifiable {
        public let target: AgentTarget
        public let state: State

        public init(target: AgentTarget, state: State) {
            self.target = target
            self.state = state
        }

        public var id: String {
            target.id
        }
    }

    /// One per target, in `AgentTarget.displayOrder`; empty when the row makes no claim.
    public let links: [Link]

    public init(links: [Link]) {
        self.links = links
    }

    public static let none = AgentReach(links: [])

    /// The agents that see the skill.
    public var linked: [Link] {
        links.filter { $0.state == .linked }
    }

    /// The agents whose link is missing, wrong or blocked, or whose store link is broken.
    public var problems: [Link] {
        links.filter(\.state.isProblem)
    }

    /// Whether the skill row draws badges. With one target every healthy row would carry the same badge, so a
    /// single-target scope shows one only when its link is broken. A not installed skill already says so in the
    /// row's trailing slot, and an unchecked link is no claim, so neither draws badges.
    public var showsOnRow: Bool {
        guard !links.isEmpty, links.allSatisfy({ $0.state == .linked || $0.state.isProblem }) else { return false }
        return links.count > 1 || !problems.isEmpty
    }
}

/// The `AgentReach` of every row of one snapshot, built once when the snapshot is set (the list reads it per row),
/// with `doctor`'s link problems parsed into one index.
///
/// The CLI links every managed skill (package, dependency, project, hand-written) into every target directory and
/// installs it in the store (`link_plan` in `src/commands.rs`), so a skill reaches every target unless `doctor`
/// names its link there. A not managed or package-only row makes no claim.
public struct AgentIndex: Sendable {
    /// How far `doctor`'s answer can be trusted for this snapshot.
    public enum LinkCheck: Hashable, Sendable {
        /// `doctor` answered in the same refresh as `status`.
        case current
        /// `doctor` has not answered yet (the first, status-only load).
        case pending
        /// `doctor` failed in the last refresh: no answer, or an older one kept for Health.
        case failed
    }

    /// The targets in `[agents] targets` order (the Agents card); each reach lists its links in
    /// `AgentTarget.displayOrder`.
    public let targets: [AgentTarget]
    public let check: LinkCheck
    private let isGlobal: Bool
    private let reaches: [SkillEntry.ID: AgentReach]

    public static let empty = AgentIndex(targets: [], check: .pending, isGlobal: false, reaches: [:])

    private init(targets: [AgentTarget], check: LinkCheck, isGlobal: Bool, reaches: [SkillEntry.ID: AgentReach]) {
        self.targets = targets
        self.check = check
        self.isGlobal = isGlobal
        self.reaches = reaches
    }

    /// - Parameter check: nil derives it from the snapshot: `.current` with a `doctor` document, else `.pending`.
    public init(snapshot: ScopeSnapshot, isGlobal: Bool, check: LinkCheck? = nil) {
        let targets = AgentTarget.resolve(snapshot.targets, isGlobal: isGlobal)
        let check = check ?? (snapshot.doctor == nil ? .pending : .current)
        let problems = check == .current ? Self.problems(snapshot.doctor, isGlobal: isGlobal) : [:]
        let missing = check == .current ? snapshot.doctor?.missingSkills ?? [] : []
        let shown = AgentTarget.displayOrder(targets)
        var reaches: [SkillEntry.ID: AgentReach] = [:]
        if !targets.isEmpty {
            for entry in snapshot.entries where entry.isLinkedByCLI {
                reaches[entry.id] = Self.reach(
                    entry, targets: shown, check: check, problems: problems[entry.name] ?? [:],
                    notInstalled: missing.contains(entry.name))
            }
        }
        self.init(targets: targets, check: check, isGlobal: isGlobal, reaches: reaches)
    }

    /// The reach of `entry`; `.none` for a row that makes no claim.
    public func reach(of entry: SkillEntry) -> AgentReach {
        reaches[entry.id] ?? .none
    }

    /// Every reach of `snapshot` (the one this index was built from), for the Agents card's broken-link counts.
    /// After a failed `doctor` they come from the document kept for Health, so the card names what Health lists:
    /// a count of known problems claims no link healthy, unlike a row's or the detail's `linked`, which an older
    /// answer may not cover (a skill added since).
    public func countedReaches(in snapshot: ScopeSnapshot) -> [AgentReach] {
        let index = check == .failed ? AgentIndex(snapshot: snapshot, isGlobal: isGlobal, check: .current) : self
        return Array(index.reaches.values)
    }

    private static func reach(
        _ entry: SkillEntry, targets: [AgentTarget], check: LinkCheck, problems: [String: AgentReach.State],
        notInstalled: Bool
    ) -> AgentReach {
        func all(_ state: AgentReach.State) -> AgentReach {
            AgentReach(links: targets.map { AgentReach.Link(target: $0, state: state) })
        }
        if entry.state == .notInstalled || notInstalled {
            return all(.notInstalled)
        }
        switch check {
        case .pending: return all(.pending)
        case .failed: return all(.unknown)
        case .current: break
        }
        // A project skill reaches every agent through its store link; when that is broken (`doctor`'s
        // `.agents/skills/<name>` line, or `status`'s `not linked`), it is the one cause for every agent. A folder
        // skillcask did not create there is the user's to move (Repair skips it), a missing or wrong link Repair's.
        if problems[AgentTarget.store] == .blocked {
            return all(.storeBlocked)
        }
        if problems[AgentTarget.store] != nil || entry.state == .notLinked {
            return all(.storeLinkBroken)
        }
        return AgentReach(
            links: targets.map { target in
                AgentReach.Link(target: target, state: target.directory.flatMap { problems[$0] } ?? .linked)
            })
    }

    /// `doctor`'s open link problems, by skill name and directory (relative to the scope root).
    static func problems(_ doctor: ScopeSnapshot.Doctor?, isGlobal: Bool) -> [String: [String: AgentReach.State]] {
        var result: [String: [String: AgentReach.State]] = [:]
        for item in doctor?.problemItems ?? [] {
            let path: String
            let state: AgentReach.State
            switch item {
            case .link(let linkPath, let problem):
                path = linkPath
                switch problem {
                case .missing: state = .missing
                case .foreign: state = .blocked
                case .wrong, .other: state = .wrong
                }
            case .notOurs(let linkPath):
                path = linkPath
                state = .blocked
            default:
                continue
            }
            let relative = DoctorItem.scopeRelative(path, isGlobal: isGlobal)
            guard let slash = relative.lastIndex(of: "/") else { continue }
            let name = String(relative[relative.index(after: slash)...])
            result[name, default: [:]][String(relative[..<slash])] = state
        }
        return result
    }
}

extension SkillEntry {
    /// The CLI links this row into the agent targets: a managed skill (package, dependency, project or
    /// hand-written). A not managed skill sits where another tool put it, and a package-only row is no skill.
    public var isLinkedByCLI: Bool {
        switch kind {
        case .package, .dependency, .project, .handWritten: true
        case .packageOnly, .notManaged: false
        }
    }
}
