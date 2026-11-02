import Foundation
import SkillcaskCore
import SkillcaskDomain

/// What the Overview tab shows for one row (Main board detail, Detail-States), as a pure value so the states are
/// testable without a view: the strips above the cards, the package facts `info` knows, and the facts the lock,
/// `status` and `audit` know, which stay when `info` is unavailable (offline).
struct OverviewContent: Hashable {
    /// One strip above the cards; a row may have several (a dependency that is abandoned).
    enum Banner: Hashable {
        /// Detail-States "Info unavailable — offline": `info` did not answer, the status-known rows stay.
        case offline
        /// Detail-States "Abandoned package": `info.abandoned`, with its replacement when it names one.
        case abandoned(replacement: String?)
        /// Detail-States "Dependency": who requires the skill.
        case dependency(skill: String, requirers: [String])
        /// Detail-States "Not managed, source known": the `status.adopt` spec.
        case notManaged(spec: String)
        /// Detail-States "Not managed, source unknown".
        case sourceUnknown
    }

    /// The right-hand cell of a label/value row, typed so the view carries no copy or colour decisions.
    enum Value: Hashable {
        /// Primary 13 pt text, with an optional fragment in mono (`^2.0`).
        case text(String, mono: String?)
        /// Secondary 13 pt text: "Nothing. Added directly to this project.", "No other skills."
        case quiet(String)
        /// A secondary mono path without an action (`Found in`).
        case mono(String)
        /// An accent link that opens `url` (Repository).
        case link(String, url: URL)
        /// The package's skills: the selected one, then every other skill of the package the scope has installed
        /// (`installedSiblings`), as accent pills; the rest plain.
        case skills(installed: [String], others: [String])
        /// A secondary mono path and the "Open folder" link.
        case folder(String, url: URL)
        /// The audit line: a dot, the text and, when `link`, "See Security".
        case security(Severity, String, link: Bool)
        /// "Available to": one line per agent target (name, directory, link state from `doctor`), then the hint
        /// of `AgentCopy.hint` when a link is broken or the skill is not installed.
        case agents(AgentReach)
    }

    /// One label/value row of a card.
    struct Row: Hashable, Identifiable {
        let label: String
        let value: Value

        var id: String { label }
    }

    /// Which board state a row is in, worst-explained first: what decides the rows the cards show.
    enum State: Hashable, CaseIterable {
        /// Main board pdf: any managed package without a more specific state.
        case package
        case project
        /// No board draws one; takes the project skill's rows.
        case local
        case dependency
        case notManaged
        case sourceUnknown
        case abandoned
        case offline
    }

    /// One row the cards can show; the table `fields(for:)` picks them per state.
    enum Field: Hashable, CaseIterable {
        // The package card, from `info`.
        case skills, license, requiredBy, requires, repository, newest
        // The place card, from the lock, `status` and `audit`.
        case kind, availableTo, location, plainLocation, foundIn, security

        /// Whether the field belongs to the package card (the first card).
        var isPackageFact: Bool {
            switch self {
            case .skills, .license, .requiredBy, .requires, .repository, .newest: true
            case .kind, .availableTo, .location, .plainLocation, .foundIn, .security: false
            }
        }
    }

    /// The rows each state shows, verbatim from the boards: Main for `package`, Detail-States for every other
    /// state. A field whose data is missing (no license, no newer version outside the range) is skipped.
    static func fields(for state: State) -> [Field] {
        switch state {
        case .package:
            [.skills, .license, .requiredBy, .requires, .repository, .newest, .availableTo, .location, .security]
        case .project, .local: [.kind, .availableTo, .location]
        case .dependency: [.requiredBy, .requires, .availableTo]
        case .notManaged, .sourceUnknown: [.foundIn, .security]
        case .abandoned: [.license, .newest]
        case .offline: [.availableTo, .plainLocation, .security]
        }
    }

    let state: State
    let banners: [Banner]
    /// The package card (Main board's first card): only when `info` answered with the package shape.
    let facts: [Row]
    /// The place card (Main board's second card): kind, agents, location, security; always known offline.
    let place: [Row]

    /// - Parameter agents: The row's reach from the store's `AgentIndex` (`ScopeStore.agentReach(for:)`).
    init(
        entry: SkillEntry, detail: SkillDetail?, snapshot: ScopeSnapshot?, scope: Scope, isOffline: Bool,
        agents: AgentReach
    ) {
        let info = detail?.info?.package == nil ? nil : detail?.info
        let offline = entry.package != nil && info == nil && (isOffline || Self.isNetworkFailure(detail?.infoError))
        let state = Self.state(of: entry, info: info, offline: offline)
        self.state = state
        banners = Self.banners(entry: entry, info: info, snapshot: snapshot, offline: offline)
        let rows = Self.fields(for: state)
            .compactMap { field in
                Self.row(
                    field, entry: entry, info: info, snapshot: snapshot, scope: scope, offline: offline, agents: agents
                )
                .map { (field, $0) }
            }
        facts = rows.filter { $0.0.isPackageFact }.map(\.1)
        place = rows.filter { !$0.0.isPackageFact }.map(\.1)
    }

    private static func state(of entry: SkillEntry, info: InfoDocument?, offline: Bool) -> State {
        if offline {
            return .offline
        }
        if info?.abandoned != nil {
            return .abandoned
        }
        switch entry.kind {
        case .dependency: return .dependency
        case .project: return .project
        case .handWritten: return .local
        case .notManaged(let adopt): return adopt == nil ? .sourceUnknown : .notManaged
        case .package, .packageOnly: return .package
        }
    }

    // MARK: - Banners

    private static func banners(
        entry: SkillEntry, info: InfoDocument?, snapshot: ScopeSnapshot?, offline: Bool
    ) -> [Banner] {
        var banners: [Banner] = []
        if offline {
            banners.append(.offline)
        }
        switch info?.abandoned {
        case nil: break
        case .withoutReplacement: banners.append(.abandoned(replacement: nil))
        case .replacedBy(let name): banners.append(.abandoned(replacement: name))
        }
        switch entry.kind {
        case .dependency(_, let via):
            let skills = snapshot?.requirerSkills(of: entry) ?? []
            let requirers = skills.isEmpty ? via : skills
            if !requirers.isEmpty {
                banners.append(.dependency(skill: entry.name, requirers: requirers))
            }
        case .notManaged(let adopt?):
            banners.append(.notManaged(spec: adopt))
        case .notManaged(nil):
            banners.append(.sourceUnknown)
        case .package, .packageOnly, .project, .handWritten:
            break
        }
        return banners
    }

    // MARK: - Rows

    /// The other skills of `entry`'s package that the scope has installed: a row of the same package whose state
    /// is `ok` (installed and matching the lock), in `siblings`' order.
    static func installedSiblings(_ siblings: [String], of entry: SkillEntry, in snapshot: ScopeSnapshot?) -> [String] {
        guard let package = entry.package, let snapshot else { return [] }
        return siblings.filter { name in
            snapshot.entries.contains { $0.name == name && $0.package == package && $0.state == .ok }
        }
    }

    private static func row(
        _ field: Field, entry: SkillEntry, info: InfoDocument?, snapshot: ScopeSnapshot?, scope: Scope, offline: Bool,
        agents: AgentReach
    ) -> Row? {
        switch field {
        case .skills:
            guard let info, info.skills.count > 1 else { return nil }
            let siblings = info.skills.map(\.name).filter { $0 != entry.name }
            let installed = installedSiblings(siblings, of: entry, in: snapshot)
            return Row(
                label: DetailOverviewCopy.skillsInPackage,
                value: .skills(installed: [entry.name] + installed, others: siblings.filter { !installed.contains($0) })
            )
        case .license:
            guard let info, !info.license.isEmpty else { return nil }
            return Row(label: DetailOverviewCopy.license, value: .text(info.license.joined(separator: ", "), mono: nil))
        case .requiredBy:
            guard let info else { return nil }
            let requirers = DetailOverviewCopy.requiredBy(why: info.why) { snapshot?.skillNames(ofPackage: $0) ?? [] }
            return Row(
                label: DetailOverviewCopy.requiredBy,
                value: requirers.map { .text($0, mono: nil) } ?? .quiet(DetailOverviewCopy.addedDirectly))
        case .requires:
            guard let info else { return nil }
            return Row(
                label: DetailOverviewCopy.requires,
                value: info.requires.isEmpty
                    ? .quiet(DetailOverviewCopy.noOtherSkills)
                    : .text(info.requires.keys.sorted().joined(separator: ", "), mono: nil))
        case .repository:
            guard let repository = info?.repository else { return nil }
            let text = DetailOverviewCopy.repositoryText(repository)
            // Package-supplied: only an http(s) link opens; any other scheme stays text (`SafeOpen`).
            let value: Value =
                URL(string: repository).flatMap { SafeOpen.isWebLink($0) ? .link(text, url: $0) : nil }
                ?? .text(text, mono: nil)
            return Row(label: DetailOverviewCopy.repository, value: value)
        case .newest:
            guard let info, let latest = entry.update?.outsideRange else { return nil }
            let range = DetailOverviewCopy.allowedRange(why: info.why)
            return Row(
                label: DetailOverviewCopy.newest,
                value: .text(DetailOverviewCopy.newest(latest, allowed: range), mono: range))
        case .kind:
            switch entry.kind {
            case .project:
                return Row(label: DetailOverviewCopy.kind, value: .text(DetailOverviewCopy.projectKind, mono: nil))
            case .handWritten:
                return Row(label: DetailOverviewCopy.kind, value: .text(DetailOverviewCopy.localKind, mono: nil))
            case .package, .dependency, .packageOnly, .notManaged: return nil
            }
        case .availableTo:
            // A not managed or package-only row makes no claim (`AgentReach.resolve`), so it has no row.
            guard !agents.links.isEmpty else { return nil }
            return Row(label: DetailOverviewCopy.availableTo, value: .agents(agents))
        case .location, .plainLocation, .foundIn:
            guard let path = entry.path else { return nil }
            let url = scope.root.appending(path: path)
            let text = DetailOverviewCopy.path(url)
            switch field {
            case .location: return Row(label: DetailOverviewCopy.location, value: .folder(text, url: url))
            case .foundIn: return Row(label: DetailOverviewCopy.foundIn, value: .mono(text))
            default: return Row(label: DetailOverviewCopy.location, value: .mono(text))
            }
        case .security:
            let findings = entry.findings.count
            // Not audited (no `audit` row) is neither a finding nor all clear: a neutral dot, no link.
            let audited = findings > 0 || entry.reach != nil
            return Row(
                label: DetailOverviewCopy.security,
                value: .security(
                    findings > 0 ? .warning : audited ? .ok : .neutral,
                    DetailOverviewCopy.security(
                        findings: findings, notManaged: entry.isNotManaged, offline: offline, reach: entry.reach),
                    link: findings > 0 || (audited && !(entry.isNotManaged || offline))))
        }
    }

    private static func isNetworkFailure(_ error: CLIError?) -> Bool {
        if case .failed(.network, _, _, _) = error { true } else { false }
    }
}
