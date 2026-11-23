import SkillcaskCore

/// What the Remove alert (S10) would remove for the selected skills, as a pure value over the scope's snapshot.
///
/// `skillcask remove` takes package names, not skills (`src/main.rs` `Remove`), and `src/commands.rs` `remove`
/// drops each from skills.toml and skills.lock with its files and links, then settles the dependencies, so:
/// - every skill of a removed package goes, selected or not (`siblings`);
/// - a dependency whose every requirer is removed goes too (`orphans`, Remove board "Dependency chain");
/// - a package that another package (one not removed with it) still requires leaves skills.toml but stays installed
///   as a dependency
///   (`kept … as a dependency`, `src/commands.rs` `remove`). `status` drops the `via` of a package that is also in
///   skills.toml, so only `info <package>`'s `why` lines (passed in as `why`) tell; a package without them is
///   `unchecked`, and the alert hedges instead of promising its files go;
/// - a dependency on its own cannot be removed ("is a dependency; remove what requires it"), and project and
///   hand-written skills are not packages: those are `refusals`;
/// - a not managed skill has no lock entry, so the CLI cannot remove it and the app changes no file of its own
///   (D35): `notManaged` lists it, and the alert only offers to reveal it.
public struct RemovePlan: Hashable, Sendable {
    /// A selected skill the alert will not remove, and why.
    public enum Refusal: Hashable, Sendable {
        /// Pulled in by `requirers` (skill names, else package names): remove what requires it.
        case dependency(skill: String, requirers: [String])
        /// A project skill (`.skills/`): edited in the repository, not installed.
        case project(String)
        /// A hand-written skill: not a package.
        case handWritten(String)
        /// Not managed, selected together with packages: left alone.
        case notManaged(String)

        public var skill: String {
            switch self {
            case .dependency(let skill, _), .project(let skill), .handWritten(let skill), .notManaged(let skill): skill
            }
        }
    }

    /// A dependency skill that goes because every package requiring it goes.
    public struct Orphan: Hashable, Sendable {
        public let skill: String
        /// The removed skills (else packages) that required it.
        public let requirers: [String]

        public init(skill: String, requirers: [String]) {
            self.skill = skill
            self.requirers = requirers
        }
    }

    /// A selected package that another package still requires: it leaves skills.toml, its files stay.
    public struct Kept: Hashable, Sendable {
        public let package: String
        /// Its skills in this scope.
        public let skills: [String]
        /// The skills (else packages) that still require it.
        public let requirers: [String]

        public init(package: String, skills: [String], requirers: [String]) {
            self.package = package
            self.skills = skills
            self.requirers = requirers
        }
    }

    /// The selected skills whose files go, in request order.
    public let selected: [String]
    /// The packages `remove` is given, in order of first selection, without duplicates.
    public let packages: [String]
    /// Skills of those packages that were not selected but go with them.
    public let siblings: [String]
    public let orphans: [Orphan]
    /// Selected packages another package still requires (known from `why`).
    public let kept: [Kept]
    /// The skills (selected or siblings) whose package has no `why` lines to check: they go unless another package
    /// requires that package.
    public let unchecked: [String]
    public let refusals: [Refusal]
    /// The not managed rows selected on their own (nothing else to remove).
    public let notManaged: [SkillEntry]
    /// The agent targets of the scope (`status.targets.entries`: `claude`, `cursor`, …), shared by every skill of
    /// the scope, so a multi-selection names each agent once.
    public let agents: [String]

    /// - Parameter why: `info <package>`'s `why` lines per package, for the packages whose document the session has
    ///   loaded; a package missing here is `unchecked`.
    public init(skills: [String], snapshot: ScopeSnapshot, why: [String: [String]] = [:]) {
        let entries = snapshot.entries
        let rows = skills.compactMap { id in entries.first { $0.id == id } }
        var selectedRows: [SkillEntry] = []
        var packages: [String] = []
        var refusals: [Refusal] = []
        var notManaged: [SkillEntry] = []
        for row in rows {
            switch row.kind {
            case .package(let package), .packageOnly(let package):
                selectedRows.append(row)
                if !packages.contains(package) {
                    packages.append(package)
                }
            case .dependency(_, let via):
                let skills = snapshot.requirerSkills(of: row)
                refusals.append(.dependency(skill: row.name, requirers: skills.isEmpty ? via : skills))
            case .project:
                refusals.append(.project(row.name))
            case .handWritten:
                refusals.append(.handWritten(row.name))
            case .notManaged:
                notManaged.append(row)
            }
        }
        if packages.isEmpty {
            self.notManaged = notManaged
        } else {
            self.notManaged = []
            refusals += notManaged.map { .notManaged($0.name) }
        }
        // `deps::wanted`: a package stays installed iff it is reachable from skills.toml through `requires`. After
        // `remove`, the roots are the manifest packages minus the removed ones; everything no longer reachable goes
        // (`settle_deps`), so kept and going are one reachability fixpoint, never two separate guesses.
        let edges = Self.edges(entries: entries, why: why)
        let roots = Set(entries.compactMap(Self.manifestPackage(of:)))
        let before = Self.reachable(from: roots, edges: edges)
        let after = Self.reachable(from: roots.subtracting(packages), edges: edges)
        let keptRequirers = Dictionary(
            uniqueKeysWithValues: packages.filter(after.contains)
                .map { package in
                    (package, edges.filter { after.contains($0.key) && $0.value.contains(package) }.map(\.key).sorted())
                })
        let selectedIDs = Set(rows.map(\.id))
        let packageRows = entries.filter { entry in
            guard let package = entry.package, packages.contains(package) else { return false }
            if case .dependency = entry.kind { return false }
            return true
        }
        kept = packages.compactMap { package in
            guard let requirers = keptRequirers[package] else { return nil }
            let names = requirers.flatMap { snapshot.skillNames(ofPackage: $0) }
            return Kept(
                package: package, skills: packageRows.filter { $0.package == package }.map(\.name),
                requirers: names.isEmpty ? requirers : Array(Set(names)).sorted())
        }
        let goes = { (entry: SkillEntry) in entry.package.map { keptRequirers[$0] == nil } ?? false }
        selected = selectedRows.filter(goes).map(\.name)
        siblings = packageRows.filter { !selectedIDs.contains($0.id) && goes($0) }.map(\.name)
        unchecked = packageRows.filter { entry in entry.package.map { why[$0] == nil } ?? false }.map(\.name)
        orphans = entries.compactMap { entry in
            guard case .dependency(let package, let via) = entry.kind, before.contains(package),
                !after.contains(package), !packages.contains(package), !selectedIDs.contains(entry.id)
            else { return nil }
            let skills = via.flatMap { snapshot.skillNames(ofPackage: $0) }
            return Orphan(skill: entry.name, requirers: skills.isEmpty ? via : Array(Set(skills)).sorted())
        }
        self.packages = packages
        self.refusals = refusals
        agents = snapshot.targets?.entries ?? []
    }

    // MARK: - Derived

    /// Every skill whose files go with `remove`: the selected ones, their package siblings, then the orphans.
    public var removedSkills: [String] {
        selected + siblings + orphans.map(\.skill)
    }

    /// There is a `remove` to run.
    public var removesPackages: Bool {
        !packages.isEmpty
    }

    /// Nothing can be removed: every selected skill is refused, not managed, or gone.
    public var isEmpty: Bool {
        packages.isEmpty
    }

    /// `remove -- <packages>`; nil when no package goes.
    public var command: Invocation.Command? {
        packages.isEmpty ? nil : .remove(packages: packages)
    }

    /// The packages that require `package`, from `info <package>`'s `why` lines as `src/commands.rs` `why` writes
    /// them: `{n}: required by {r1} ({c1}), {r2} ({c2})`. `why` walks the requirers transitively, so only lines whose
    /// subject is `package` count; every `r (c)` after "required by " is read (the constraint in parentheses may
    /// itself hold a comma). Lines of any other shape (`in skills.toml as …`, `in skills.lock only; …`) give none.
    public static func requirers(of package: String, why: [String]) -> [String] {
        let marker = "\(package): required by "
        var found: [String] = []
        for line in why where line.hasPrefix(marker) {
            var rest = Substring(line.dropFirst(marker.count))
            while !rest.isEmpty {
                guard let open = rest.range(of: " (") else {
                    let name = rest.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { found.append(name) }
                    break
                }
                let name = rest[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !found.contains(name) { found.append(name) }
                // Skip the parenthesised constraint, nesting included, then the ", " separator.
                var depth = 1
                var index = open.upperBound
                while index < rest.endIndex, depth > 0 {
                    if rest[index] == "(" { depth += 1 } else if rest[index] == ")" { depth -= 1 }
                    index = rest.index(after: index)
                }
                rest = rest[index...]
                guard rest.hasPrefix(", ") else {
                    break
                }
                rest = rest.dropFirst(2)
            }
        }
        return found
    }

    /// The skills.toml entry a row stands for, as `deps::wanted` roots its walk at every manifest entry: a package
    /// row, or a package-only row that `status` prints for a drifted manifest entry (`constraint changed …`,
    /// `not in skills.lock`, …). A `not in skills.toml` row is a lock-only package and a package-only row with a
    /// `via` list is a drifted dependency (`src/commands.rs` status, its `via` key): neither is a root.
    public static func manifestPackage(of entry: SkillEntry) -> String? {
        switch entry.kind {
        case .package(let package): return package
        // A drifted dependency (a `via` list and no skill) is no manifest entry either.
        case .packageOnly(let package): return entry.state == .notInManifest || !entry.via.isEmpty ? nil : package
        case .dependency, .project, .handWritten, .notManaged: return nil
        }
    }

    /// requirer → the packages it requires, from the snapshot's dependency rows (`via`) and every `required by`
    /// line of the loaded `why` documents (they walk requirers transitively, so they also tell about other packages).
    public static func edges(entries: [SkillEntry], why: [String: [String]]) -> [String: Set<String>] {
        var edges: [String: Set<String>] = [:]
        for entry in entries {
            guard case .dependency(let package, let via) = entry.kind else { continue }
            for requirer in via {
                edges[requirer, default: []].insert(package)
            }
        }
        for line in why.values.joined() {
            guard let range = line.range(of: ": required by ") else { continue }
            let subject = String(line[..<range.lowerBound])
            for requirer in requirers(of: subject, why: [line]) {
                edges[requirer, default: []].insert(subject)
            }
        }
        return edges
    }

    /// Every package reachable from `roots` along `edges`; a cycle is visited once.
    public static func reachable(from roots: Set<String>, edges: [String: Set<String>]) -> Set<String> {
        var seen = roots
        var queue = Array(roots)
        while let next = queue.popLast() {
            for dependency in edges[next] ?? [] where seen.insert(dependency).inserted {
                queue.append(dependency)
            }
        }
        return seen
    }
}
