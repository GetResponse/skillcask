import SkillcaskDomain

/// The words of the per-skill agent badges (skill row) and the per-agent lines of the detail's "Available to" row:
/// agent names and monograms, link states, what VoiceOver reads for a row's badges, and the remedy hint. No board
/// draws them; worded after the Agents card (`OverviewCopy`) and Health's link sentences.
public enum AgentCopy {
    // MARK: - Names

    /// `Claude Code` for a preset, the path as written for a path target (`./tools/skills`).
    public static func name(_ target: AgentTarget) -> String {
        target.isPath ? target.entry : ShellCopy.agentName(target.entry)
    }

    /// The two-letter text monogram of a badge (`CC`, `Cu`, `Cx`): two letters because six presets start with C.
    /// Nil for a path target, which draws `pathSymbol` instead. Text only: no vendor logo is ever drawn.
    public static func monogram(_ target: AgentTarget) -> String? {
        guard !target.isPath else { return nil }
        switch target.entry {
        case "claude": return "CC"
        case "cursor": return "Cu"
        case "codex": return "Cx"
        case "copilot": return "Cp"
        case "cline": return "Cl"
        case "kiro": return "Ki"
        case "junie": return "Ju"
        case "gemini": return "Ge"
        case "opencode": return "OC"
        case "amp": return "Am"
        case "devin": return "De"
        case "roo": return "Ro"
        case "goose": return "Go"
        case "factory": return "Fa"
        case "vibe": return "Vi"
        default:
            let letters = target.entry.filter(\.isLetter)
            guard let first = letters.first else { return "?" }
            return first.uppercased() + letters.dropFirst().prefix(1).lowercased()
        }
    }

    /// The glyph of a path target's badge.
    public static let pathSymbol = "folder"

    /// `+2`: the badges a narrow row leaves out.
    public static func overflow(_ count: Int) -> String {
        "+\(count)"
    }

    // MARK: - States

    /// The short state column of a detail line: `linked`, `link missing`, `blocked`. An agent that reads the store
    /// has no link of its own, so its healthy state is `installed`. What a state means and what fixes it is the
    /// hint's.
    public static func state(_ state: AgentReach.State, readsStore: Bool = false) -> String {
        switch state {
        case .linked: readsStore ? "installed" : "linked"
        case .missing: "link missing"
        case .wrong: "link wrong"
        case .blocked: "blocked"
        case .storeLinkBroken: "store link broken"
        case .storeBlocked: "store blocked"
        case .notInstalled: "not installed"
        case .pending: "checking…"
        case .unknown: "not checked"
        }
    }

    /// A badge's tooltip: `Cursor · .agents/skills · installed`, `Kiro · .kiro/skills · link missing`.
    public static func help(_ link: AgentReach.Link) -> String {
        [
            name(link.target), link.target.shownPath,
            state(link.state, readsStore: link.target.directory == nil),
        ]
        .joined(separator: RowCopy.separator)
    }

    // MARK: - Row summary (VoiceOver)

    /// What VoiceOver reads for a row's agents: `Available to Claude Code and Cursor`, `Available to Claude Code;
    /// Kiro link missing`, `Available to no agent; store link broken` (one cause for every agent, said once).
    public static func summary(_ reach: AgentReach) -> String {
        let linked = reach.linked.map { name($0.target) }
        let available = linked.isEmpty ? "Available to no agent" : "Available to \(OutcomeCopy.list(linked))"
        var problems: [String] = []
        if let store = reach.problems.first(where: \.state.isStoreProblem) {
            problems.append(state(store.state))
        }
        problems += reach.problems.filter { !$0.state.isStoreProblem }
            .map { "\(name($0.target)) \(state($0.state))" }
        return problems.isEmpty ? available : "\(available); \(OutcomeCopy.list(problems))"
    }

    // MARK: - Detail hint

    /// The quiet line under the detail's agent lines, and whether it ends in the "See Health" link: what the worst
    /// state means and what fixes it; nil when every agent sees the skill.
    public static func hint(_ reach: AgentReach) -> (text: String, seeHealth: Bool)? {
        let states = Set(reach.links.map(\.state))
        if states.contains(.notInstalled) {
            return ("Not installed, so no agent sees it. Sync installs it and links it.", false)
        }
        if states.contains(.unknown) {
            return ("The links could not be checked: the last check failed.", true)
        }
        if states.contains(.pending) {
            return ("Checking the links…", false)
        }
        if states.contains(.storeBlocked) {
            return (
                "A file or folder skillcask did not create holds this name in .agents/skills, so no agent sees it. "
                    + "Move it away, then Repair.", true
            )
        }
        if states.contains(.storeLinkBroken) {
            return ("The skill’s link into .agents/skills is broken, so no agent sees it. Repair fixes this.", true)
        }
        if states.contains(.blocked) {
            return ("A file or folder skillcask did not create holds this name. Move it away, then Repair.", true)
        }
        if states.contains(.missing) || states.contains(.wrong) {
            return ("Repair fixes missing and wrong links.", true)
        }
        return nil
    }

    /// The hint's link to the Scope Overview's Health card.
    public static let seeHealth = "See Health"
}
