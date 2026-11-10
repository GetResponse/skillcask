import Foundation
import Observation
import SkillcaskCore
import SkillcaskDomain

/// The Add Skill sheet's state (S8): the field, the debounced `search`, the skills.sh consent,
/// the selected result and its `info` preview, the version rule, the provided skills and the rename, and the `add`
/// command they make. One per sheet presentation; reads the scope's snapshot (what is installed, the policy, the
/// repositories) and runs read-only commands through the scope's client. The mutation itself runs through
/// `SheetRun`, never here.
///
/// - Typing debounces `search --json -- <term>` by `debounce` (300 ms); a newer keystroke cancels the
///   previous task, and a generation guard drops an answer that lands after a newer query started.
/// - A source typed into the field (`PackageSpec`: `vendor/name`, `github:…`, `git:https://…`) skips search and
///   becomes the selection after the same debounce, so its preview comes straight from `info`.
/// - `info --json -- <package>` downloads the dist (about a second): it runs only for the selected result, is
///   cancelled when the selection moves, and is cached for the sheet's lifetime. After an add in this sheet the
///   added package's previews are read again when their rows are next selected (`added(_:)`); the added row
///   keeps its preview while it stays selected.
@MainActor @Observable final class SearchStore {
    /// The results column.
    enum Results: Hashable {
        /// Nothing searched: the field is empty or holds a source.
        case idle
        case searching
        case loaded(SearchDocument)
        case failed(UserMessage)
    }

    /// The preview pane.
    enum Preview: Hashable {
        /// No selection.
        case none
        case loading
        case loaded(InfoDocument)
        case failed(UserMessage)
    }

    /// A skill of the package whose name is already taken in the scope by another package (AddSkill-States "Name
    /// clash"); offered a rename only where the CLI has `add --rename`.
    struct NameClash: Hashable {
        /// The provided skill's name, the key of `--rename`.
        let skill: String
        /// The package that already installs a skill of that name.
        let existingPackage: String
        /// `<vendor>-<skill>`, as the CLI suggests it (`suggest` in `src/commands.rs`).
        let suggestion: String
    }

    /// What the user chose for an `add`: the row, and the rule, skills and name set in its preview. Not the command
    /// built from them, which also reads `info` and the scope's snapshot and so can change under the same choices.
    struct Choices: Hashable {
        let selection: String?
        /// The chosen rule, a branch with its name; nil while the CLI's default stands.
        let rule: VersionRule?
        let excludedSkills: Set<String>
        let renameTo: String
    }

    /// A source the results can be narrowed to, and how many of the loaded results it has.
    struct SourceChip: Hashable {
        /// The repository or source name, the value of `sourceFilter`.
        let name: String
        let kind: SourceKind
        let count: Int
    }

    static let defaultDebounce: Duration = .milliseconds(300)

    let store: ScopeStore
    let debounce: Duration

    // MARK: - State

    /// The field. Setting it cancels the pending search or preview and schedules the next one.
    var query: String {
        didSet {
            if query != oldValue, !isPreloading {
                queryChanged()
            }
        }
    }
    private(set) var results: Results = .idle
    /// What the last `search` said about skills.sh; `.undecided` shows the consent card.
    private(set) var skillsSh: SearchDocument.SkillsSh = .unknown
    /// The consent card was answered in this sheet: it never comes back, whatever a late document says.
    private(set) var consentAnswered = false
    /// The selected result's `name`, or the source typed into the field; the key of `infos`.
    var selection: String? {
        didSet {
            if selection != oldValue, !isPreloading {
                selectionChanged()
            }
        }
    }
    /// The results' source filter: a chip's `name`, nil for All. A new query keeps it; a filter that hides the
    /// selected result clears the selection.
    var sourceFilter: String? {
        didSet {
            if sourceFilter != oldValue, !isPreloading {
                clearHiddenSelection()
            }
        }
    }
    private(set) var infos: [String: InfoDocument] = [:]
    private(set) var infoErrors: [String: UserMessage] = [:]
    /// The version rule the popover chose; nil leaves the constraint to the CLI (`cliDefaultRule`). A `.branch`
    /// stands for `.branch(branch)`.
    var rule: VersionRule?
    /// The Branch rule's branch name.
    var branch = ""
    /// Provided skills unticked in the preview; only honoured where the CLI has `add --skill`.
    var excludedSkills: Set<String> = []
    /// The name typed into the rename field; prefilled with the clash's suggestion.
    var renameTo = ""
    /// What was chosen for the `add` that just exited 0 for the selection (`added(_:)`); nil once the selection
    /// moved.
    private(set) var justAdded: Choices?

    @ObservationIgnored private(set) var searchTask: Task<Void, Never>?
    @ObservationIgnored private(set) var infoTask: Task<Void, Never>?
    /// The consent answer's run: never cancelled, so `--remember` reaches config.toml.
    @ObservationIgnored private(set) var consentTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isEnded = false
    @ObservationIgnored private var isPreloading = false

    @ObservationIgnored private var hasBegun = false
    /// Selections whose cached `info` predates their add in this sheet.
    @ObservationIgnored private var staleInfos: Set<String> = []

    /// A store for `scope`'s sheet, with the field pre-filled (`AppStore.Sheet.addSkill(query:)`). Runs nothing
    /// until `begin()`: a view's `init` may build it more than once.
    init(store: ScopeStore, query: String? = nil, debounce: Duration = SearchStore.defaultDebounce) {
        self.store = store
        self.debounce = debounce
        self.query = query ?? ""
    }

    /// The sheet appeared: a pre-filled field is searched (or previewed) at once, without the debounce. Runs once.
    func begin() {
        guard !hasBegun else { return }
        hasBegun = true
        if !query.isEmpty {
            schedule(after: .zero)
        }
    }

    // MARK: - Derived

    /// The field read as a source; nil for a search term.
    var source: PackageSpec? {
        PackageSpec.parse(query)
    }

    /// The field as a search term; nil when it is empty or a source.
    var term: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || source != nil ? nil : trimmed
    }

    /// The results, most installs first (results without a count keep the CLI's order, after the counted ones).
    var sortedResults: [SearchDocument.Result] {
        guard case .loaded(let document) = results else { return [] }
        return document.results.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.installs, rhs.element.installs) {
                case (let left?, let right?) where left != right: left > right
                case (.some, nil): true
                case (nil, .some): false
                default: lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// The sorted results of `sourceFilter`'s source; every result for All. A blocked repository's results show only
    /// in All.
    var filteredResults: [SearchDocument.Result] {
        guard let sourceFilter else { return sortedResults }
        return sortedResults.filter { isInChip($0, named: sourceFilter) }
    }

    /// Every loaded result, whatever the filter.
    var totalResultCount: Int {
        guard case .loaded(let document) = results else { return 0 }
        return document.results.count
    }

    /// A filter whose source has none of the loaded results: the empty state that offers Show All.
    var isFilterEmpty: Bool {
        guard case .loaded = results else { return false }
        return sourceFilter != nil && filteredResults.isEmpty
    }

    /// The header's filter chips: the allowed repositories in their order, skills.sh when it is searched, the other
    /// sources the results name (first seen first), then the active filter when nothing else matches it, so its
    /// chip stays. A blocked repository's results, and results without a source, count only in All.
    var sourceChips: [SourceChip] {
        guard case .loaded(let document) = results else { return [] }
        var chips: [(name: String, kind: SourceKind)] = repositories.filter(\.allowed).map { ($0.name, $0.kind) }
        func isChip(_ source: String) -> Bool {
            chips.contains { Self.source(source, matches: $0.name) }
        }
        if skillsSh == .enabled, !isChip("skills.sh") {
            chips.append(("skills.sh", .skillsSh))
        }
        for source in document.results.compactMap(\.source) where !isChip(source) && !isBlocked(source) {
            chips.append((source, SourceKind(parsing: source)))
        }
        if let sourceFilter, !isChip(sourceFilter) {
            chips.append((sourceFilter, SourceKind(parsing: sourceFilter)))
        }
        return chips.map { chip in
            SourceChip(
                name: chip.name, kind: chip.kind, count: document.results.count { isInChip($0, named: chip.name) })
        }
    }

    /// Whether any shown result carries an install count, so the header can say what it is sorted by.
    var isSortedByInstalls: Bool {
        filteredResults.contains { $0.installs != nil }
    }

    /// The consent card: the CLI has no `[search] skills-sh` yet and the card was not answered here.
    var showsConsent: Bool {
        guard case .loaded = results else { return false }
        return skillsSh == .undecided && !consentAnswered
    }

    /// Packages in the scope's lock (`status` entries), by lock name, lowercased.
    var installedPackages: Set<String> {
        Set(store.snapshot?.entries.compactMap { $0.package?.lowercased() } ?? [])
    }

    /// The Installed marker: the result's package is already in this scope's lock.
    func isInstalled(_ result: SearchDocument.Result) -> Bool {
        installedPackages.contains(PackageSpec.packageName(of: result.name))
    }

    /// The skills a result's package already installs in this scope (`Already in this project as jira-cli.`).
    func installedSkills(of result: SearchDocument.Result) -> [String] {
        let package = PackageSpec.packageName(of: result.name)
        return store.snapshot?.entries.filter { $0.package?.lowercased() == package }.map(\.name) ?? []
    }

    /// A result from a repository this scope's policy does not allow (`status.repositories[].allowed`).
    func isBlocked(_ result: SearchDocument.Result) -> Bool {
        result.source.map(isBlocked) ?? false
    }

    private func isBlocked(_ source: String) -> Bool {
        blockedRepositories.contains { Self.source(source, matches: $0) }
    }

    /// The result counts in the chip `name`: its source matches and is not blocked. A result without a source
    /// belongs to no chip.
    private func isInChip(_ result: SearchDocument.Result, named name: String) -> Bool {
        guard let source = result.source else { return false }
        return Self.source(source, matches: name) && !isBlocked(source)
    }

    /// A source belongs to the repository or chip of the same name ignoring case, and to nothing else: the CLI
    /// stamps each result's `source` with the repository's `name` or `skills.sh`, so there are no aliases to
    /// resolve, and a repository named `composer` stays apart from `packagist`.
    private static func source(_ source: String, matches name: String) -> Bool {
        name.caseInsensitiveCompare(source) == .orderedSame
    }

    /// The scope's repositories as the header's pills: allowed first in the CLI's order, then the blocked ones.
    var repositories: [(name: String, kind: SourceKind, allowed: Bool)] {
        let all = store.snapshot?.repositories ?? []
        return (all.filter(\.allowed) + all.filter { !$0.allowed })
            .map { ($0.name, SourceKind(parsing: $0.name), $0.allowed) }
    }

    private var blockedRepositories: [String] {
        repositories.filter { !$0.allowed }.map(\.name)
    }

    /// The selected search result among the shown ones; nil for a typed source.
    var selectedResult: SearchDocument.Result? {
        guard let selection else { return nil }
        return filteredResults.first { $0.name == selection }
    }

    /// The selection as a spec `add` takes; nil when nothing is selected or the name has no spec shape.
    var selectedSpec: PackageSpec? {
        selection.flatMap(PackageSpec.parse)
    }

    var preview: Preview {
        guard let selection else { return .none }
        if let info = infos[selection] {
            return .loaded(info)
        }
        if let error = infoErrors[selection] {
            return .failed(error)
        }
        return .loading
    }

    /// The selection's `info`, once loaded.
    var info: InfoDocument? {
        selection.flatMap { infos[$0] }
    }

    // MARK: - Version rule

    /// `policy.allow-ranges` of the scope; true unless the policy says `false`.
    var allowsRanges: Bool {
        Self.allowsRanges(store.snapshot)
    }

    /// `policy.allow-ranges` of `snapshot`; true unless the policy says `false`.
    static func allowsRanges(_ snapshot: ScopeSnapshot?) -> Bool {
        snapshot?.policy.first { $0.key == "allow-ranges" }?.value != "false"
    }

    /// The version `info` says `add` would install, when it is a number the rule can be built from. Nil hides the
    /// rule: no info yet, a git ref, or a constraint typed into the field.
    var ruleBase: VersionRule.Base? {
        guard selectedSpec?.pinned == nil, let version = info?.version else { return nil }
        return VersionRule.Base(version)
    }

    var cliDefaultRule: VersionRule {
        VersionRule.cliDefault(allowRanges: allowsRanges)
    }

    /// The rule the button shows: the chosen one, else what the CLI writes by default.
    var effectiveRule: VersionRule {
        if case .branch = rule {
            return .branch(branch)
        }
        return rule ?? cliDefaultRule
    }

    /// Flow-F2's rules for the selection: the version rules, Latest, and Branch for a GitHub or git source.
    var ruleOptions: [VersionRule] {
        guard let ruleBase else { return [] }
        return VersionRule.options(
            for: ruleBase, allowRanges: allowsRanges, source: selectedSpec?.kind, branch: branch)
    }

    /// The constraint appended to the spec: only for a rule the user chose; without one the CLI picks its default.
    var constraint: String? {
        guard rule != nil, let ruleBase else { return nil }
        return effectiveRule.constraint(for: ruleBase)
    }

    /// The Branch rule is chosen with a name the CLI would refuse or read as a version: Add stays disabled.
    var hasBranchProblem: Bool {
        guard ruleBase != nil, case .branch(let name) = effectiveRule else { return false }
        return !VersionRule.isValidBranch(name)
    }

    // MARK: - Provided skills and rename

    /// `add --skill`: the provided skills can be chosen. Without it (0.9.4) every provided skill is added.
    var canChooseSkills: Bool {
        store.capabilities.supports(.addSkill)
    }

    /// `add --rename`: a clashing skill can be installed under another name. Without it (0.9.4) the clash is the
    /// CLI's error and hint after Add.
    var canRename: Bool {
        store.capabilities.supports(.addRename)
    }

    /// The skills the preview lists: the package's, or only the one a `github:owner/repo/skill` spec selects
    /// (skills.sh results have that shape; `info` reads the whole repository).
    var providedSkills: [InfoDocument.Skill] {
        let all = info?.skills ?? []
        guard let skill = selectedSpec?.skill else { return all }
        return all.filter { $0.name == skill }
    }

    /// The provided skills that will be added: every one, unless the CLI can choose and some were unticked. A
    /// `github:…/skill` spec adds its one skill.
    var chosenSkills: [String] {
        if let skill = selectedSpec?.skill {
            return [skill]
        }
        let all = providedSkills.map(\.name)
        return canChooseSkills ? all.filter { !excludedSkills.contains($0) } : all
    }

    /// The constraint of the package's existing skills.toml entry, from `info`'s `why`
    /// (`vendor/name: in skills.toml as "^4.2"`): `add` keeps it when no constraint is given
    /// (`src/commands.rs` `add`).
    var existingConstraint: String? {
        guard let info, let package = info.package ?? selectedSpec?.package else { return nil }
        let prefix = "\(package): in skills.toml as \""
        guard let line = info.why.first(where: { $0.hasPrefix(prefix) && $0.hasSuffix("\"") }) else { return nil }
        return String(line.dropFirst(prefix.count).dropLast())
    }

    /// The minimum release age `info` applied to the selection, when it can be known: the CLI takes a repository's
    /// own `min-release-age` before the policy's (`Manifest::min_release_age`, `src/manifest.rs`), and no `--json`
    /// document prints a repository's override, so only GitHub and git sources (resolved with the policy's age,
    /// `github::resolve`) have a known age. Registry packages, and a zero or absent policy age, give nil: the
    /// preview then says only which version will be installed.
    var knownMinimumAge: String? {
        guard let kind = selectedSpec?.kind, kind != .registry,
            let value = store.snapshot?.policy.first(where: { $0.key == "min-release-age" })?.value,
            !ScopeSnapshot.PolicyRow.isZeroAge(value)
        else { return nil }
        return value
    }

    /// The package already has a skills.toml entry or lock entry in this scope.
    var hasEntry: Bool {
        existingConstraint != nil || selectedSpec.map { installedPackages.contains($0.package) } == true
    }

    /// The entry's constraint the rule button shows while no rule was chosen; nil otherwise.
    var keptConstraint: String? {
        rule == nil ? existingConstraint : nil
    }

    /// The first chosen skill whose name another package already installs in this scope; only computed where the
    /// CLI can rename.
    var clash: NameClash? {
        guard canRename, let spec = selectedSpec, let entries = store.snapshot?.entries else { return nil }
        for skill in chosenSkills {
            if let entry = entries.first(where: { $0.name == skill }), let package = entry.package,
                package.lowercased() != spec.package
            {
                return NameClash(
                    skill: skill, existingPackage: package, suggestion: Self.suggestion(for: spec.package, skill: skill)
                )
            }
        }
        return nil
    }

    /// `<vendor>-<skill>`, every character of the vendor that is not a letter or digit turned into `-`.
    static func suggestion(for package: String, skill: String) -> String {
        let vendor = package.split(separator: "/").first.map(String.init) ?? ""
        let safe = String(vendor.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return "\(safe)-\(skill)"
    }

    // MARK: - Add

    /// The `add` command of the current choices; nil while nothing addable is selected (no spec, every provided
    /// skill unticked, an empty rename).
    var command: Invocation.Command? {
        guard let spec = selectedSpec, !hasBranchProblem else { return nil }
        let all = providedSkills.map(\.name)
        let chosen = chosenSkills
        if canChooseSkills, spec.skill == nil, !all.isEmpty, chosen.isEmpty {
            return nil
        }
        let skills = canChooseSkills && spec.skill == nil && chosen.count < all.count ? chosen : []
        var rename: [String: String] = [:]
        if let clash {
            let name = renameTo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            rename[clash.skill] = name
        }
        return .add(
            spec: spec.text(constraint: constraint), repository: repository(for: spec), adopt: false, rename: rename,
            skills: skills)
    }

    /// The choices as they stand.
    var choices: Choices {
        Choices(
            selection: selection, rule: rule == nil ? nil : effectiveRule, excludedSkills: excludedSkills,
            renameTo: renameTo.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The choices are those of the `add` that just succeeded: the sheet stays open on the added row, where Return
    /// would run it a second time (the CLI resolves the package again, rewrites its entry and prints `added` once
    /// more, `src/commands.rs` `add`). Another skill, rule or name is a different `add`, and so is the same one
    /// after the selection moved: then it is the re-add every installed package allows.
    var isRepeat: Bool {
        justAdded == choices
    }

    /// An `add` with `choices` exited 0 for the selection: it is not offered again while the selection stays, and
    /// every cached preview of its package (the selection, and other rows of the same repository such as
    /// `github:owner/repo/other-skill`), which says what `add` would do to a package not yet in the lock, is read
    /// again when its row is next selected.
    func added(_ choices: Choices) {
        justAdded = choices
        guard let selection else { return }
        let package = PackageSpec.packageName(of: selection)
        staleInfos.formUnion(infos.keys.filter { PackageSpec.packageName(of: $0) == package })
    }

    /// `--repository <name>` when the result came from a custom repository of the scope: what the user picked,
    /// not whichever repository the CLI tries first. Packagist, GitHub and git sources take no flag.
    private func repository(for spec: PackageSpec) -> String? {
        guard spec.kind == .registry, let source = selectedResult?.source,
            case .custom = SourceKind(parsing: source)
        else { return nil }
        return source
    }

    // MARK: - Actions

    /// Answers the consent card: runs the search again with `--skills-sh` or `--no-skills-sh` and `--remember`,
    /// which writes `[search] skills-sh` to config.toml (the Settings switch reads the same key).
    ///
    /// The answer runs in a task of its own that neither a keystroke nor closing the sheet cancels, so it always
    /// reaches config.toml; its results replace the list only while the query is still the one it answered.
    func answerConsent(include: Bool) {
        consentAnswered = true
        guard let term else { return }
        searchTask?.cancel()
        generation += 1
        let generation = generation
        results = .searching
        let command = Invocation.Command.search(query: term, skillsSh: include ? .include : .exclude, remember: true)
        consentTask = Task { [weak self] in
            guard let outcome = await self?.read(SearchDocument.self, command), let self else { return }
            if case .success(let document) = outcome {
                skillsSh = document.skillsSh
            }
            guard generation == self.generation, !isEnded else { return }
            apply(outcome)
        }
    }

    /// The sheet closed: cancels the pending search and preview; nothing new starts. The consent answer, once
    /// sent, still finishes.
    func end() {
        isEnded = true
        generation += 1
        searchTask?.cancel()
        infoTask?.cancel()
    }

    /// Runs the current search again now (Retry after a network failure).
    func retry() {
        schedule(after: .zero)
    }

    /// Loads the selection's preview again after a failure.
    func retryPreview() {
        selectionChanged()
    }

    private func queryChanged() {
        selection = nil
        rule = nil
        excludedSkills = []
        schedule(after: debounce)
    }

    private func schedule(after delay: Duration) {
        guard !isEnded else { return }
        if let source {
            searchTask?.cancel()
            generation += 1
            let generation = generation
            results = .idle
            searchTask = Task { [weak self] in
                guard (try? await Task.sleep(for: delay)) != nil, let self, generation == self.generation else {
                    return
                }
                selection = source.text
            }
        } else if let term {
            start(term: term, choice: nil, remember: false, after: delay)
        } else {
            searchTask?.cancel()
            generation += 1
            results = .idle
        }
    }

    private func start(term: String, choice: Invocation.SkillsShChoice?, remember: Bool, after delay: Duration) {
        searchTask?.cancel()
        generation += 1
        let generation = generation
        searchTask = Task { [weak self] in
            if delay > .zero {
                guard (try? await Task.sleep(for: delay)) != nil else { return }
            }
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            results = .searching
            let outcome = await read(SearchDocument.self, .search(query: term, skillsSh: choice, remember: remember))
            guard generation == self.generation, !Task.isCancelled else { return }
            apply(outcome)
        }
    }

    private func apply(_ outcome: Result<SearchDocument, CLIError>) {
        switch outcome {
        case .success(let document):
            results = .loaded(document)
            skillsSh = document.skillsSh
            clearHiddenSelection()
        case .failure(.cancelled):
            break
        case .failure(let error):
            results = .failed(ErrorCopy.message(for: error))
        }
    }

    private func selectionChanged() {
        infoTask?.cancel()
        rule = nil
        excludedSkills = []
        renameTo = ""
        justAdded = nil
        if let selection, staleInfos.remove(selection) != nil {
            infos[selection] = nil
        }
        guard !isEnded, let selection, infos[selection] == nil else {
            prefillRename()
            return
        }
        // A result that failed before is read again: its old error would stand beside (or over) the new answer.
        infoErrors[selection] = nil
        let target = selectedSpec?.infoTarget ?? selection
        infoTask = Task { [weak self] in
            guard let outcome = await self?.read(InfoDocument.self, .info(.package(target))), let self,
                self.selection == selection, !Task.isCancelled, !isEnded
            else { return }
            switch outcome {
            case .success(let document):
                infos[selection] = document
                prefillRename()
            case .failure(.cancelled):
                break
            case .failure(let error):
                infoErrors[selection] = AddSkillCopy.previewFailure(
                    error, spec: selectedSpec, source: selectedResult?.source.map(SourceKind.init(parsing:)),
                    personal: store.scope.isPersonal)
            }
        }
    }

    /// Drops a selected result the filter or a new document no longer shows; never selects one. A typed source
    /// (`results == .idle`) is left alone.
    private func clearHiddenSelection() {
        guard case .loaded = results, let selection, !filteredResults.contains(where: { $0.name == selection })
        else { return }
        self.selection = nil
    }

    private func prefillRename() {
        renameTo = clash?.suggestion ?? ""
    }

    private func read<T: Decodable & Sendable>(
        _ type: T.Type, _ command: Invocation.Command
    ) async -> Result<T, CLIError> {
        let client = store.client
        do {
            let invocation = try Invocation(command, in: store.scope, capabilities: store.capabilities)
            return .success(try await client.document(type, for: invocation))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Previews

    /// Previews and the render tool: a state without running anything.
    func preload(
        query: String, results: Results = .idle, skillsSh: SearchDocument.SkillsSh = .unknown,
        consentAnswered: Bool = false, selection: String? = nil, info: InfoDocument? = nil,
        infoError: UserMessage? = nil
    ) {
        isPreloading = true
        hasBegun = true
        defer { isPreloading = false }
        searchTask?.cancel()
        infoTask?.cancel()
        self.query = query
        self.results = results
        self.skillsSh = skillsSh
        self.consentAnswered = consentAnswered
        self.selection = selection
        if let selection {
            infos[selection] = info
            infoErrors[selection] = infoError
        }
        prefillRename()
    }
}
