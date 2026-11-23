import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The Add Skill sheet's logic: the debounced search and its stale answers, the skills.sh consent, the
/// Installed marker, the spec with its version rule, the gating on `add --skill` and `add --rename`, and Add through
/// `SheetRun` (failure, cancel; what a success leaves in the open sheet is `AddSkillVisitTests`). Source-shape
/// detection is `PackageSpecTests`. Views are not tested; their inputs are.
@Suite @MainActor struct AddSkillTests {
    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/add-tests"))
    static let jira = "netresearch/agent-jira-skill"
    static let searchJira = Invocation.Command.search(query: "jira", skillsSh: nil, remember: false)
    /// A GitHub repository the api scope has no entry for.
    static let freshRepository = "github:acme/jira-kit"
    static let freshInfo = DesignFixtures.decode(
        InfoDocument.self,
        json:
            #"{"package":"acme/jira-kit","version":"1.0.0","locked":false,"skills":[{"name":"alpha"},{"name":"beta"}],"versions":["1.0.0"]}"#
    )
    static let capable = Capabilities(version: Capabilities.minimum, features: [.addSpecs, .addRename])

    /// A store over the api board's snapshot (its lock, policy and repositories) in the test scope.
    func store(capabilities: Capabilities = Capabilities(version: Capabilities.minimum)) -> ScopeStore {
        let store = ScopeStore(scope: scope, client: client, capabilities: capabilities) { _ in SkillText.parse("") }
        store.preload(snapshot: DesignFixtures.api)
        return store
    }

    func search(
        capabilities: Capabilities = Capabilities(version: Capabilities.minimum), debounce: Duration = .zero
    )
        -> SearchStore
    {
        SearchStore(store: store(capabilities: capabilities), debounce: debounce)
    }

    static let searchJSON = DesignFixtures.text("search.jira", "json")
    static let undecided =
        #"{"results":[{"name":"acme/jira-triage","description":null,"source":"acme"}],"skills-sh":null}"#

    // MARK: - Search

    @Test(.timeLimit(.minutes(1))) func typingDebouncesAndRunsOnlyTheLastQuery() async {
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let search = search(debounce: .milliseconds(200))
        search.query = "j"
        search.query = "ji"
        search.query = "jira"
        await search.searchTask?.value
        #expect(await client.commands == [Self.searchJira])
        #expect(search.sortedResults.count == 7)
    }

    @Test(.timeLimit(.minutes(1))) func aStaleAnswerNeverReplacesTheNewerQuery() async {
        let gate = Gate()
        let stale = Invocation.Command.search(query: "ji", skillsSh: nil, remember: false)
        await client.json(stale, in: scope, Self.undecided, gate: gate)
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let search = search()
        search.query = "ji"
        let first = search.searchTask
        await gate.arrived()
        search.query = "jira"
        await search.searchTask?.value
        await gate.open()
        await first?.value
        #expect(search.sortedResults.map(\.name).first == Self.jira)
        #expect(search.sortedResults.count == 7, "the stale one-result answer was dropped")
    }

    @Test(.timeLimit(.minutes(1))) func aTypedSourceSkipsSearchAndPreviewsFromInfo() async {
        let source = "git:https://git.acme.example/team/sql-review.git"
        await client.json(.info(.package(source)), in: scope, #"{"package":"team/sql-review","skills":[]}"#)
        let search = search()
        search.query = source
        await search.searchTask?.value
        await search.infoTask?.value
        #expect(search.selection == source && search.results == .idle)
        #expect(await client.commands == [.info(.package(source))])
        #expect(search.info?.package == "team/sql-review")
    }

    @Test(.timeLimit(.minutes(1))) func resultsSortByInstallsAndKeepTheCLIOrderAfterThem() async {
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let search = search()
        search.query = "jira"
        await search.searchTask?.value
        #expect(
            search.sortedResults.map(\.name) == [
                Self.jira, "atlassian/jira-cli-skill", "kolya/jira-to-md", "acme/jira-triage",
                "github:ankit/jira-helper",
                "netresearch/jira-skill", "netresearch/german-technical-writing-skill",
            ])
        #expect(search.isSortedByInstalls)
    }

    @Test(.timeLimit(.minutes(1))) func aNetworkFailureIsRetried() async {
        await client.script(
            Self.searchJira, in: scope,
            .error(.failed(code: .network, message: "Couldn’t reach packagist.", hint: nil, stderr: "")))
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let search = search()
        search.query = "jira"
        await search.searchTask?.value
        guard case .failed(let message) = search.results else {
            Issue.record("expected the failure, got \(search.results)")
            return
        }
        #expect(message.remedy == .retry && FailureBanner.showsRetry(message))
        search.retry()
        await search.searchTask?.value
        #expect(search.sortedResults.count == 7)
    }

    // MARK: - Consent

    @Test(.timeLimit(.minutes(1))) func consentAnswerSearchesAgainWithRemember() async throws {
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let include = Invocation.Command.search(query: "jira", skillsSh: .include, remember: true)
        await client.json(
            include, in: scope,
            Self.searchJSON.replacingOccurrences(of: #""skills-sh": null"#, with: #""skills-sh": true"#))
        let search = search()
        search.query = "jira"
        await search.searchTask?.value
        #expect(search.showsConsent)
        search.answerConsent(include: true)
        #expect(!search.showsConsent, "the card goes away at once")
        await search.consentTask?.value
        let last = try #require(await client.invocations.last)
        #expect(last.command == include)
        #expect(last.argv == ["search", "--json", "--skills-sh", "--remember", "--", "jira"])
        #expect(search.skillsSh == .enabled && !search.showsConsent)
    }

    @Test(.timeLimit(.minutes(1))) func notNowIsRememberedToo() async throws {
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let exclude = Invocation.Command.search(query: "jira", skillsSh: .exclude, remember: true)
        await client.json(exclude, in: scope, Self.searchJSON)
        let search = search()
        search.query = "jira"
        await search.searchTask?.value
        search.answerConsent(include: false)
        await search.consentTask?.value
        #expect(try #require(await client.invocations.last).argv.contains("--no-skills-sh"))
        #expect(!search.showsConsent, "a late null in the document does not bring the card back")
    }

    // MARK: - Installed and blocked

    @Test func installedMarkerComesFromTheScopesLock() throws {
        let search = search()
        search.preload(query: "jira", results: .loaded(DesignFixtures.jiraSearch))
        let byName = Dictionary(uniqueKeysWithValues: search.sortedResults.map { ($0.name, $0) })
        let jira = try #require(byName[Self.jira])
        #expect(search.isInstalled(jira))
        #expect(search.installedSkills(of: jira) == ["jira-syntax", "jira-communication"])
        let cli = try #require(byName["atlassian/jira-cli-skill"])
        #expect(!search.isInstalled(cli), "api has no jira-cli (only personal does)")
        #expect(
            search.isBlocked(try #require(byName["github:ankit/jira-helper"])), "api's policy does not allow github")
        #expect(!search.isBlocked(try #require(byName["acme/jira-triage"])))
    }

    // MARK: - Spec and version rule

    @Test func specCarriesTheChosenRuleOnly() {
        let search = search()
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        #expect(search.command == .add(spec: Self.jira, repository: nil, adopt: false, rename: [:], skills: []))
        #expect(search.effectiveRule == .compatible && search.ruleOptions == [.compatible, .patches, .exact, .latest])
        search.rule = .compatible
        #expect(
            search.command == .add(spec: "\(Self.jira)@^4.2", repository: nil, adopt: false, rename: [:], skills: []))
        search.rule = .patches
        #expect(search.constraint == "~4.2.0")
        search.rule = .exact
        #expect(search.constraint == "4.2.0")
    }

    @Test func ruleFollowsTheCLIDefaults() throws {
        let zero = try #require(VersionRule.Base("v0.0.3"))
        #expect(VersionRule.compatible.constraint(for: zero) == "^0.0.3")
        let minor = try #require(VersionRule.Base("0.3.1-beta"))
        #expect(VersionRule.compatible.constraint(for: minor) == "^0.3")
        #expect(VersionRule.options(for: minor, allowRanges: true) == [.compatible, .exact])
        #expect(VersionRule.options(for: minor, allowRanges: false) == [.exact])
        #expect(VersionRule.cliDefault(allowRanges: false) == .exact)
        #expect(VersionRule.Base("main") == nil, "a git ref gets no rule")
    }

    @Test func aTypedPinHidesTheRule() {
        let search = search()
        search.preload(query: "\(Self.jira)@4.1.2", selection: "\(Self.jira)@4.1.2", info: AddSkillSamples.jiraInfo)
        search.rule = .compatible
        #expect(search.ruleBase == nil)
        #expect(
            search.command == .add(spec: "\(Self.jira)@4.1.2", repository: nil, adopt: false, rename: [:], skills: []))
    }

    @Test func aCustomRepositoryResultIsPinnedToIt() {
        let search = search()
        search.preload(
            query: "jira", results: .loaded(DesignFixtures.jiraSearch), selection: "acme/jira-triage",
            info: AddSkillSamples.jiraInfo)
        guard case .add(_, let repository, let adopt, _, _) = search.command else {
            Issue.record("no add command")
            return
        }
        #expect(repository == "acme" && !adopt)
    }

    // MARK: - Capability gating

    @Test func atZeroNineOneEverySkillIsAddedAndAClashIsLeftToTheCLI() throws {
        let search = search()
        search.preload(
            query: AddSkillSamples.kolyaPackage, selection: AddSkillSamples.kolyaPackage,
            info: AddSkillSamples.kolyaInfo)
        search.excludedSkills = ["pdf"]
        #expect(!search.canChooseSkills && !search.canRename)
        #expect(search.chosenSkills == ["pdf"] && search.clash == nil)
        let command = try #require(search.command)
        #expect(
            command == .add(spec: AddSkillSamples.kolyaPackage, repository: nil, adopt: false, rename: [:], skills: []))
        let argv = try Invocation(command, in: scope, capabilities: search.store.capabilities).argv
        #expect(!argv.contains("--skill") && !argv.contains("--rename") && !argv.contains("--adopt"))
        #expect(throws: CLIError.unsupported(feature: "add with several specs")) {
            try Invocation(
                .add(spec: "a/b", repository: nil, adopt: false, rename: [:], skills: ["x"]), in: scope,
                capabilities: Capabilities(version: Capabilities.minimum))
        }
    }

    // D72: a GitHub repository's ticked skills go as one `github:owner/repo/skill` spec each; a registry package
    // has no spec per skill, so it is added whole.
    @Test func withSeveralSpecsTheUntickedSkillsOfAGitHubRepositoryAreLeftOut() throws {
        let registry = search(capabilities: Self.capable)
        registry.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        #expect(!registry.canChooseSkills)

        let github = Self.freshRepository
        let search = search(capabilities: Self.capable)
        search.preload(query: github, selection: github, info: Self.freshInfo)
        #expect(search.canChooseSkills)
        #expect(
            try #require(search.command) == .add(spec: github, repository: nil, adopt: false, rename: [:], skills: []))
        search.excludedSkills = ["beta"]
        let command = try #require(search.command)
        #expect(command == .add(spec: github, repository: nil, adopt: false, rename: [:], skills: ["alpha"]))
        let argv = try Invocation(command, in: scope, capabilities: Self.capable).argv
        #expect(argv.suffix(2) == ["--", "\(github)/alpha"] && !argv.contains("--skill"))
        search.excludedSkills = ["alpha", "beta"]
        #expect(search.command == nil, "nothing to add")
    }

    @Test func aGitHubSkillResultLeadsToItsWholeRepository() {
        let search = search(capabilities: Self.capable)
        search.preload(
            query: "pdf", selection: "github:anthropics/skills/pdf@^1", info: AddSkillSamples.jiraInfo)
        #expect(search.wholeRepository == "github:anthropics/skills@^1")
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        #expect(search.wholeRepository == nil)
        search.preload(query: "github:o/r", selection: "github:o/r", info: AddSkillSamples.jiraInfo)
        #expect(search.wholeRepository == nil, "the whole repository does not link to itself")
    }

    // Review of #90: once the package is locked, `info` lists only the lock's skills, so the link and the boxes
    // would show the installed skills as the whole repository and offer unticks that remove nothing.
    @Test func aLockedGitHubRepositoryKeepsItsSkillsAndHasNoLink() {
        let search = search(capabilities: Self.capable)
        search.preload(
            query: "github:netresearch/agent-jira-skill/jira-syntax",
            selection: "github:netresearch/agent-jira-skill/jira-syntax", info: DesignFixtures.jiraPackageInfo)
        #expect(search.wholeRepository == nil)
        search.preload(
            query: AddSkillSamples.githubJira, selection: AddSkillSamples.githubJira,
            info: DesignFixtures.jiraPackageInfo)
        #expect(!search.canChooseSkills)
        #expect(
            search.command
                == .add(spec: AddSkillSamples.githubJira, repository: nil, adopt: false, rename: [:], skills: []))
    }

    // Review of #90: for a bare `github:owner/repo` `add` keeps the entry's selection, so ticking the skill left out
    // of the first add must name every skill, or it is never installed.
    @Test func afterAPartialAddEveryTickedSkillIsNamed() throws {
        let github = Self.freshRepository
        let search = search(capabilities: Self.capable)
        search.preload(query: github, selection: github, info: Self.freshInfo)
        search.excludedSkills = ["beta"]
        search.added(search.choices)
        search.excludedSkills = []
        let command = try #require(search.command)
        #expect(
            command
                == .add(
                    spec: github, repository: nil, adopt: false, rename: [:],
                    skills: ["alpha", "beta"]))
    }

    @Test func aChosenRuleGoesWithEverySkillSpec() throws {
        let github = AddSkillSamples.githubJira
        let search = search(capabilities: Self.capable)
        search.preload(query: github, selection: github, info: AddSkillSamples.jiraInfo)
        search.excludedSkills = ["jira-communication"]
        search.rule = .exact
        let argv = try Invocation(try #require(search.command), in: scope, capabilities: Self.capable).argv
        #expect(argv.suffix(2) == ["--", "\(github)/jira-syntax@4.2.0"])
    }

    @Test func aRegistryPackageOnANewCLISaysEverySkillIsAdded() {
        let search = search(capabilities: Self.capable)
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        #expect(search.skillsNote == AddSkillCopy.everySkillAdded)
        let old = self.search()
        old.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        #expect(old.skillsNote == AddSkillCopy.allSkillsAdded)
    }

    // D72: several selected results are one `add`, in the list's order (by installs, not by name), each spec as
    // the CLI's default takes it.
    @Test func severalSelectedResultsAreAddedTogether() throws {
        let search = search(capabilities: Self.capable)
        search.preload(query: "jira", results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled)
        search.selections = ["netresearch/jira-skill", "github:ankit/jira-helper", "kolya/jira-to-md"]
        let order = ["kolya/jira-to-md", "github:ankit/jira-helper", "netresearch/jira-skill"]
        #expect(search.batch == order && search.selection == nil)
        #expect(search.preview == .none && search.batchProblem == nil)
        let command = try #require(search.command)
        #expect(command == .addMany(specs: order, repository: nil))
        let invocation = try Invocation(command, in: scope, capabilities: Self.capable)
        #expect(invocation.argv == ["add", "--"] + order)
        #expect(invocation.isMutation && invocation.needsNetwork && !invocation.expectsDocument)

        search.selections = ["kolya/jira-to-md"]
        #expect(search.batch.isEmpty && search.selection == "kolya/jira-to-md", "one is a selection again")
    }

    @Test func aNewQueryClearsTheBatch() {
        let search = search(capabilities: Self.capable)
        search.preload(query: "jira", results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled)
        search.selections = ["kolya/jira-to-md", "netresearch/jira-skill"]
        search.query = "pdf"
        #expect(search.batch.isEmpty && search.selection == nil)
    }

    @Test func aBatchTakesOneRepositoryForAll() throws {
        let search = search(capabilities: Self.capable)
        search.preload(query: "jira", results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled)
        search.selections = ["acme/jira-triage", "atlassian/jira-cli-skill"]
        #expect(search.batchProblem == AddSkillCopy.batchMixesRepositories, "--repository acme would apply to both")
        #expect(search.command == nil)
        search.sourceFilter = "acme"
        #expect(search.batch.isEmpty && search.selection == "acme/jira-triage", "the filter hides the other one")

        let acme = DesignFixtures.decode(
            SearchDocument.self,
            json: #"{"results":[{"name":"acme/a","source":"acme"},{"name":"acme/b","source":"acme"}]}"#)
        search.preload(query: "acme", results: .loaded(acme), skillsSh: .disabled)
        search.selections = ["acme/a", "acme/b"]
        #expect(try #require(search.command) == .addMany(specs: ["acme/a", "acme/b"], repository: "acme"))

        let named = DesignFixtures.decode(
            SearchDocument.self,
            json: #"{"results":[{"name":"acme/lint","source":"acme"},{"name":"acme/b","source":"acme"}]}"#)
        search.preload(query: "acme", results: .loaded(named), skillsSh: .disabled)
        search.selections = ["acme/lint", "acme/b"]
        #expect(search.batchProblem == AddSkillCopy.batchHasEntry(["acme/lint"]), "--repository may move its entry")
    }

    // Review after #91: two skills of one GitHub repository were refused as "selected more than once"; `add`
    // merges them into one entry (D72).
    @Test func aBatchTakesSeveralSkillsOfOneRepositoryButNotTheSamePackageTwice() throws {
        let search = search(capabilities: Self.capable)
        let tool = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:vendor/tool/a","source":"github"},{"name":"github:vendor/tool/b","source":"github"},
                {"name":"github:vendor/tool","source":"github"},{"name":"vendor/tool","source":"packagist"}]}
                """#)
        search.preload(query: "tool", results: .loaded(tool), skillsSh: .disabled)
        search.selections = ["github:vendor/tool/a", "github:vendor/tool/b"]
        #expect(search.batchProblem == nil)
        #expect(
            try #require(search.command)
                == .addMany(specs: ["github:vendor/tool/a", "github:vendor/tool/b"], repository: nil))
        for pair: Set<String> in [
            ["vendor/tool", "github:vendor/tool/a"], ["github:vendor/tool", "github:vendor/tool/a"],
        ] {
            search.selections = pair
            #expect(search.batchProblem == AddSkillCopy.batchSamePackage(["vendor/tool"]) && search.command == nil)
        }
    }

    // Review of #93: only the first package selected twice was named.
    @Test func aBatchNamesEveryPackageSelectedTwice() {
        let search = search(capabilities: Self.capable)
        let twice = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"vendor/a","source":"packagist"},{"name":"github:vendor/a","source":"github"},
                {"name":"vendor/b","source":"packagist"},{"name":"github:vendor/b","source":"github"}]}
                """#)
        search.preload(query: "vendor", results: .loaded(twice), skillsSh: .disabled)
        search.selections = Set(twice.results.map(\.name))
        #expect(search.batchProblem == AddSkillCopy.batchSamePackage(["vendor/a", "vendor/b"]))
    }

    // Review of #93: ⌘A over Installed rows updated each of them with no word of it.
    @Test func aBatchSaysWhichInstalledPackagesAddUpdates() {
        let search = search(capabilities: Self.capable)
        search.preload(query: "jira", results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled)
        search.selections = [Self.jira, "kolya/jira-to-md"]
        #expect(search.batchUpdates == [Self.jira] && search.command != nil)
        search.selections = ["atlassian/jira-cli-skill", "kolya/jira-to-md"]
        #expect(search.batchUpdates.isEmpty)
    }

    // Review after #91: every result already in skills.toml refused the whole batch, and only the first was named.
    // Now only an entry `add` may replace is refused: a `github:` result's entry is read for its source.
    @Test(.timeLimit(.minutes(1))) func aBatchRefusesOnlyTheEntriesAddMayReplace() async throws {
        await client.json(
            .info(.package(Self.jira)), in: scope, #"{"package":"netresearch/agent-jira-skill","source":"composer"}"#)
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#)
        await client.json(.info(.package("acme/lint")), in: scope, #"{"package":"acme/lint","source":"git"}"#)
        let search = search(capabilities: Self.capable)
        let named = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"netresearch/agent-jira-skill","source":"packagist"},
                {"name":"github:anthropics/skills/pdf","source":"github"},
                {"name":"github:netresearch/agent-jira-skill/jira-syntax","source":"github"},
                {"name":"github:acme/lint","source":"github"}]}
                """#)
        search.preload(query: "jira", results: .loaded(named), skillsSh: .disabled)
        search.selections = ["netresearch/agent-jira-skill", "github:anthropics/skills/pdf"]
        #expect(
            search.isCheckingBatch && search.command == nil && search.batchProblem == nil, "Add waits for the entry")
        await search.batchTask?.value
        #expect(!search.isCheckingBatch && search.batchProblem == nil, "a re-add, and a skill joining a GitHub entry")
        #expect(search.command != nil)

        search.selections = Set(search.filteredResults.map(\.name).dropFirst())
        await search.batchTask?.value
        #expect(
            search.batchProblem == AddSkillCopy.batchHasEntry(["netresearch/agent-jira-skill", "acme/lint"]),
            "a Packagist and a git entry are replaced, and both are named")
        #expect(search.command == nil)
        #expect(
            await client.commands == [
                .info(.package("anthropics/skills")), .info(.package(Self.jira)), .info(.package("acme/lint")),
            ],
            "each entry is read once")
    }

    // Review after #91: a `github:` result of a package this sheet just added from Packagist went through before
    // the refresh named it in skills.toml.
    @Test func aBatchKnowsTheKindOfWhatThisSheetAdded() {
        let search = search(capabilities: Self.capable)
        let tool = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"vendor/tool","source":"packagist"},{"name":"github:vendor/tool/s","source":"github"},
                {"name":"github:other/kit/s","source":"github"},{"name":"github:other/kit/t","source":"github"}]}
                """#)
        search.preload(query: "tool", results: .loaded(tool), skillsSh: .disabled, selection: "vendor/tool")
        search.added(search.choices)
        search.selections = ["github:vendor/tool/s", "github:other/kit/s"]
        #expect(search.batchProblem == AddSkillCopy.batchHasEntry(["vendor/tool"]) && search.command == nil)
        #expect(!search.isCheckingBatch, "nothing to read: the sheet knows the entry")

        search.selections = ["github:other/kit/s"]
        search.added(search.choices)
        search.selections = ["github:other/kit/t", "vendor/tool"]
        #expect(search.batchProblem == nil, "another skill of a GitHub entry this sheet added, and a re-add")

        // Review of #93: an add from Packagist let a custom repository's result move the entry (`--repository`).
        let acme = DesignFixtures.decode(
            SearchDocument.self,
            json: #"{"results":[{"name":"vendor/tool","source":"acme"},{"name":"acme/b","source":"acme"}]}"#)
        search.preload(query: "acme", results: .loaded(acme), skillsSh: .disabled)
        search.selections = ["vendor/tool", "acme/b"]
        #expect(search.batchProblem == AddSkillCopy.batchHasEntry(["vendor/tool"]), "added from Packagist, not acme")
        search.selections = ["vendor/tool"]
        search.added(search.choices)
        search.selections = ["vendor/tool", "acme/b"]
        #expect(search.batchProblem == nil, "a re-add from the repository this sheet added it from")
    }

    // Review of #93: a batch selected before the scope's skills.toml named its repository showed "Checking
    // skills.toml…" for good, since nothing read the entry the new snapshot called for.
    @Test(.timeLimit(.minutes(1))) func aSnapshotThatNamesARepositoryLaterReadsItsEntry() async throws {
        let store = store(capabilities: Self.capable)
        let search = SearchStore(store: store, debounce: .zero)
        let tool = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:vendor/tool/a","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "tool", results: .loaded(tool), skillsSh: .disabled)
        search.selections = ["github:vendor/tool/a", "kolya/jira-to-md"]
        #expect(!search.isCheckingBatch && search.command != nil, "vendor/tool has no entry")

        await client.json(.info(.package("vendor/tool")), in: scope, #"{"package":"vendor/tool","source":"github"}"#)
        store.preload(
            snapshot: AddSkillSamples.apiSnapshot { entries in
                entries + [["package": "vendor/tool", "skill": "z", "version": "1.0.0", "state": "ok", "ok": true]]
            })
        #expect(!search.isCheckingBatch && search.command == nil, "not read yet: nothing is pending, and Add waits")
        search.snapshotChanged()
        #expect(search.isCheckingBatch)
        await search.batchTask?.value
        #expect(!search.isCheckingBatch && search.batchProblem == nil && search.command != nil)
    }

    // Review of #93: one failed read refused the batch for the rest of the sheet, saying Add would replace the
    // entry.
    @Test(.timeLimit(.minutes(1))) func aFailedEntryReadSaysSoAndIsReadAgain() async throws {
        await client.script(
            .info(.package("anthropics/skills")), in: scope,
            .error(.failed(code: .network, message: "Couldn’t reach github.com.", hint: nil, stderr: "")))
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#)
        let search = search(capabilities: Self.capable)
        let pdf = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:anthropics/skills/pdf","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"},
                {"name":"netresearch/jira-skill","source":"packagist"}]}
                """#)
        search.preload(query: "pdf", results: .loaded(pdf), skillsSh: .disabled)
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md"]
        await search.batchTask?.value
        #expect(search.batchProblem == AddSkillCopy.batchEntryUnread(["anthropics/skills"]) && search.command == nil)
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md", "netresearch/jira-skill"]
        await search.batchTask?.value
        #expect(search.batchProblem == nil && search.command != nil, "read again on the next batch")
    }

    // Review of #93: every batch change and every refresh cancelled the read in flight and ran `info` again.
    @Test(.timeLimit(.minutes(1))) func aReadInFlightIsNotRestarted() async throws {
        let gate = Gate()
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#,
            gate: gate)
        let search = search(capabilities: Self.capable)
        let pdf = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:anthropics/skills/pdf","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"},
                {"name":"netresearch/jira-skill","source":"packagist"}]}
                """#)
        search.preload(query: "pdf", results: .loaded(pdf), skillsSh: .disabled)
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md"]
        await gate.arrived()
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md", "netresearch/jira-skill"]
        search.snapshotChanged()
        #expect(search.isCheckingBatch && search.command == nil)
        await gate.open()
        await search.batchTask?.value
        #expect(!search.isCheckingBatch && search.command != nil)
        #expect(await client.commands == [.info(.package("anthropics/skills"))], "read once")
    }

    // Review of #93: an entry `status` shows as a package row only (drifted, or not in the lock yet) was not
    // named, so a `github:` result went through unread and replaced it.
    @Test(.timeLimit(.minutes(1))) func aDriftedEntryIsReadToo() async throws {
        await client.json(.info(.package("vendor/tool")), in: scope, #"{"package":"vendor/tool","source":"composer"}"#)
        let store = store(capabilities: Self.capable)
        store.preload(
            snapshot: AddSkillSamples.apiSnapshot { entries in
                entries + [
                    ["package": "vendor/tool", "state": "constraint changed from \"^1\" to \"^2\"", "ok": false]
                ]
            })
        let search = SearchStore(store: store, debounce: .zero)
        let tool = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:vendor/tool/a","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "tool", results: .loaded(tool), skillsSh: .disabled)
        search.selections = ["github:vendor/tool/a", "kolya/jira-to-md"]
        #expect(search.isCheckingBatch)
        await search.batchTask?.value
        #expect(search.batchProblem == AddSkillCopy.batchHasEntry(["vendor/tool"]) && search.command == nil)
    }

    // Review of #93: an entry read once was trusted for the rest of the sheet, though skills.toml changed outside.
    @Test(.timeLimit(.minutes(1))) func anEntryIsReadAgainWhenSkillsTomlChanges() async throws {
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#)
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"composer"}"#)
        let store = store(capabilities: Self.capable)
        let search = SearchStore(store: store, debounce: .zero)
        let pdf = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:anthropics/skills/pdf","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "pdf", results: .loaded(pdf), skillsSh: .disabled)
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md"]
        await search.batchTask?.value
        #expect(search.batchProblem == nil)
        search.snapshotChanged()
        #expect(!search.isCheckingBatch, "the same skills.toml: nothing to read")
        store.preload(
            snapshot: AddSkillSamples.apiSnapshot { entries in
                entries + [["package": "anthropics/skills", "state": "repository changed", "ok": false]]
            })
        search.snapshotChanged()
        await search.batchTask?.value
        #expect(search.batchProblem == AddSkillCopy.batchHasEntry(["anthropics/skills"]))
    }

    // Review of #95: a read that started before skills.toml changed was stored as current: an entry that had become
    // a registry one was read as `github`, and Add would have replaced it.
    @Test(.timeLimit(.minutes(1))) func aReadFromBeforeSkillsTomlChangedIsReadAgain() async throws {
        let gate = Gate()
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#,
            gate: gate)
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"composer"}"#)
        let store = store(capabilities: Self.capable)
        let search = SearchStore(store: store, debounce: .zero)
        let pdf = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:anthropics/skills/pdf","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "pdf", results: .loaded(pdf), skillsSh: .disabled)
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md"]
        await gate.arrived()
        store.preload(
            snapshot: AddSkillSamples.apiSnapshot { entries in
                entries + [["package": "anthropics/skills", "state": "repository changed", "ok": false]]
            })
        search.snapshotChanged()
        await gate.open()
        await search.batchTask?.value
        #expect(search.batchProblem == AddSkillCopy.batchHasEntry(["anthropics/skills"]) && search.command == nil)
        #expect(await client.commands.count == 2, "read again for the new entry")
    }

    // Review of #95: the line about installed packages missed a result joining a skill to an installed entry.
    @Test(.timeLimit(.minutes(1))) func aBatchSaysWhichPackagesAddResolvesAgain() async throws {
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#)
        let store = store(capabilities: Self.capable)
        store.preload(
            snapshot: AddSkillSamples.apiSnapshot { entries in
                entries + [
                    ["package": "anthropics/skills", "skill": "pdf", "version": "1.0.0", "state": "ok", "ok": true]
                ]
            })
        let search = SearchStore(store: store, debounce: .zero)
        let docx = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:anthropics/skills/docx","source":"github"},{"name":"github:anthropics/skills/xlsx","source":"github"},
                {"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "docx", results: .loaded(docx), skillsSh: .disabled)
        search.selections = Set(docx.results.map(\.name))
        await search.batchTask?.value
        #expect(search.batchProblem == nil && search.batchUpdates == ["anthropics/skills"], "named once, a join")
    }

    // Review of #93: a failed read had no retry while the selection stayed.
    @Test(.timeLimit(.minutes(1))) func aFailedEntryReadIsRetried() async throws {
        await client.script(
            .info(.package("anthropics/skills")), in: scope,
            .error(.failed(code: .network, message: "Couldn’t reach github.com.", hint: nil, stderr: "")))
        await client.json(
            .info(.package("anthropics/skills")), in: scope, #"{"package":"anthropics/skills","source":"github"}"#)
        let search = search(capabilities: Self.capable)
        let pdf = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:anthropics/skills/pdf","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "pdf", results: .loaded(pdf), skillsSh: .disabled)
        search.selections = ["github:anthropics/skills/pdf", "kolya/jira-to-md"]
        await search.batchTask?.value
        let problem = try #require(search.batchProblem)
        #expect(FailureBanner.showsRetry(problem))
        search.retryBatchEntries()
        await search.batchTask?.value
        #expect(search.batchProblem == nil && search.command != nil)
    }

    // Review of #93: a registry re-add over a GitHub entry recorded the entry as a registry one, so the
    // repository's other skills were refused for the rest of the sheet.
    @Test func aRegistryReAddKeepsTheEntrysKind() {
        let search = search(capabilities: Self.capable)
        let tool = DesignFixtures.decode(
            SearchDocument.self,
            json: #"""
                {"results":[{"name":"github:vendor/tool/a","source":"github"},{"name":"vendor/tool","source":"packagist"},
                {"name":"github:vendor/tool/b","source":"github"},{"name":"kolya/jira-to-md","source":"packagist"}]}
                """#)
        search.preload(query: "tool", results: .loaded(tool), skillsSh: .disabled, selection: "github:vendor/tool/a")
        search.added(search.choices)
        search.selections = ["vendor/tool"]
        search.added(search.choices)
        search.selections = ["github:vendor/tool/b", "kolya/jira-to-md"]
        #expect(search.batchProblem == nil, "b joins the GitHub entry")
    }

    // Review after #91: no test failed when a reload kept the batch in its old order, or when Add ran while the
    // reloading list showed none of its rows (a hidden row's `--repository` is not known).
    @Test(.timeLimit(.minutes(1))) func aReloadReordersTheBatchAndHoldsAddMeanwhile() async throws {
        let command = Invocation.Command.search(query: "vendor", skillsSh: nil, remember: false)
        let a = #"{"name":"vendor/a","source":"packagist"}"#
        let b = #"{"name":"vendor/b","source":"packagist"}"#
        await client.json(command, in: scope, #"{"results":[\#(a),\#(b)],"skills-sh":false}"#)
        let gate = Gate()
        await client.json(command, in: scope, #"{"results":[\#(b),\#(a)],"skills-sh":false}"#, gate: gate)
        let search = search(capabilities: Self.capable)
        search.query = "vendor"
        await search.searchTask?.value
        search.selections = ["vendor/a", "vendor/b"]
        #expect(search.batch == ["vendor/a", "vendor/b"] && search.command != nil)
        search.retry()
        await gate.arrived()
        #expect(search.batch.count == 2 && search.command == nil, "no row is shown while the list reloads")
        await gate.open()
        await search.searchTask?.value
        #expect(search.batch == ["vendor/b", "vendor/a"])
        #expect(try #require(search.command) == .addMany(specs: ["vendor/b", "vendor/a"], repository: nil))
    }

    // Review of #91: ⇧-click and ⌘A with an older CLI kept an arbitrary row of the set.
    @Test func withoutSeveralSpecsTheListKeepsOneSelection() {
        let search = search()
        search.preload(
            query: "jira", results: .loaded(DesignFixtures.jiraSearch), skillsSh: .disabled,
            selection: "atlassian/jira-cli-skill")
        search.selections = ["atlassian/jira-cli-skill", "kolya/jira-to-md"]
        #expect(search.batch.isEmpty && search.selection == "kolya/jira-to-md", "the newly clicked row wins")
        search.selections = Set(search.filteredResults.map(\.name))
        #expect(search.selection == "netresearch/agent-jira-skill", "the first new row in list order")
    }

    @Test func withAddRenameAClashIsPrefilledVendorDashName() throws {
        let search = search(capabilities: Self.capable)
        search.preload(
            query: AddSkillSamples.kolyaPackage, selection: AddSkillSamples.kolyaPackage,
            info: AddSkillSamples.kolyaInfo)
        let clash = try #require(search.clash)
        #expect(clash.skill == "pdf" && clash.existingPackage == "anthropics/skills" && clash.suggestion == "kolya-pdf")
        #expect(search.renameTo == "kolya-pdf")
        let command = try #require(search.command)
        #expect(
            try Invocation(command, in: scope, capabilities: Self.capable).argv
                == ["add", "--rename", "pdf=kolya-pdf", "--", "kolya/pdf-tools"])
        search.renameTo = " "
        #expect(search.command == nil, "an empty rename cannot be added")
        #expect(SearchStore.suggestion(for: "my.org/x", skill: "pdf") == "my-org-pdf")
    }

    // MARK: - Preview

    @Test(.timeLimit(.minutes(1))) func infoRunsForTheSelectionOnlyAndIsCachedPerSheet() async {
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        await client.json(.info(.package(Self.jira)), in: scope, #"{"package":"netresearch/agent-jira-skill"}"#)
        let search = search()
        search.query = "jira"
        await search.searchTask?.value
        #expect(search.preview == .none, "no result is selected, so nothing is downloaded")
        search.selection = Self.jira
        await search.infoTask?.value
        search.selection = nil
        search.selection = Self.jira
        await search.infoTask?.value
        #expect(await client.commands == [Self.searchJira, .info(.package(Self.jira))])
        #expect(search.info?.package == Self.jira)
    }

    @Test(.timeLimit(.minutes(1))) func movingTheSelectionCancelsTheDownload() async {
        let gate = Gate()
        await client.json(
            .info(.package("acme/jira-triage")), in: scope, #"{"package":"acme/jira-triage"}"#, gate: gate)
        await client.json(.info(.package(Self.jira)), in: scope, #"{"package":"netresearch/agent-jira-skill"}"#)
        let search = search()
        search.selection = "acme/jira-triage"
        let first = search.infoTask
        await gate.arrived()
        search.selection = Self.jira
        await gate.open()
        await first?.value
        await search.infoTask?.value
        #expect(search.infos["acme/jira-triage"] == nil, "the cancelled download left nothing behind")
        #expect(search.info?.package == Self.jira)
    }

    @Test func notFoundAndPolicyFailuresAreWordedAsTheBoard() throws {
        let notFound = AddSkillSamples.notFound
        #expect(notFound.title == "Couldn’t find acme/jira-triage-v2.")
        #expect(notFound.reason == "No package with that name in packagist or acme.")
        #expect(notFound.action == "Check the spelling, or search for “jira triage” instead.")
        #expect(ResultPreview.followUp(for: notFound) == .searchName)
        let blocked = AddSkillSamples.blocked
        #expect(blocked.title == "GitHub is not an allowed source for this project.")
        #expect(blocked.reason?.hasPrefix("Allowed sources are packagist, acme") == true)
        #expect(blocked.severity == .warning && blocked.monoFragment == "packagist, acme")
        #expect(ResultPreview.followUp(for: blocked) == .searchAllowed)
        #expect(ResultPreview.followUp(for: AddSkillSamples.unreachable) == nil, "network failures offer Retry")
        #expect(AddSkillCopy.searchTerm(for: try #require(PackageSpec.parse("acme/jira-triage-v2"))) == "jira triage")
    }

    @Test func installNoteNamesTheMinimumReleaseAgeOnlyWhenItIsTheCause() {
        let info = AddSkillSamples.jiraInfo
        #expect(
            ResultPreview.installNote(info, minimumAge: "72h", pinned: false, hasEntry: false)
                == "4.2.0 will be installed; 4.3.0 is inside your 72 h minimum release age")
        #expect(
            ResultPreview.installNote(info, minimumAge: "72h", pinned: true, hasEntry: false)
                == "4.2.0 will be installed", "a typed constraint may be the cause")
        #expect(
            ResultPreview.installNote(info, minimumAge: "72h", pinned: false, hasEntry: true)
                == "4.2.0 will be installed", "the entry's constraint may be the cause")
        #expect(
            ResultPreview.installNote(info, minimumAge: nil, pinned: false, hasEntry: false)
                == "4.2.0 will be installed")
        let beta = DesignFixtures.decode(
            InfoDocument.self, json: #"{"version":"4.2.0","locked":false,"versions":["4.3.0-beta.1","4.2.0"]}"#)
        #expect(
            ResultPreview.installNote(beta, minimumAge: "72h", pinned: false, hasEntry: false)
                == "4.2.0 will be installed", "the stability filter may be the cause")
        #expect(
            ResultPreview.installNote(DesignFixtures.jiraPackageInfo, minimumAge: "72h", pinned: false, hasEntry: false)
                == nil, "locked")
        #expect(
            ResultPreview.metaParts(info, installs: 4100) == ["MIT", "4.1k installs", "newest 4.3.0"])
    }

    @Test func anExistingEntryKeepsItsConstraintAndSilencesTheAge() {
        let search = search()
        let info = DesignFixtures.jiraPackageInfo
        search.preload(query: Self.jira, selection: Self.jira, info: info)
        #expect(search.existingConstraint == "^4.2" && search.keptConstraint == "^4.2" && search.hasEntry)
        #expect(search.command == .add(spec: Self.jira, repository: nil, adopt: false, rename: [:], skills: []))
        search.rule = .exact
        #expect(search.keptConstraint == nil && search.constraint == "4.3.0")
    }

    @Test func ageIsClaimedOnlyWhereTheRepositoryCannotOverrideIt() async throws {
        let search = search()
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        #expect(search.knownMinimumAge == nil, "a registry repository may override the policy's 72h")
        search.preload(query: "github:acme/x", selection: "github:acme/x", info: AddSkillSamples.jiraInfo)
        #expect(search.knownMinimumAge == "3d", "GitHub resolves with the policy's age")
        #expect(ScopeSnapshot.PolicyRow.isZeroAge("0h") && ScopeSnapshot.PolicyRow.isZeroAge("0"))
        #expect(ScopeSnapshot.PolicyRow.isZeroAge("") && !ScopeSnapshot.PolicyRow.isZeroAge("3d"))
    }

    @Test func exactPadsShortVersions() throws {
        #expect(VersionRule.exact.constraint(for: try #require(VersionRule.Base("1.2"))) == "1.2.0")
        #expect(VersionRule.exact.constraint(for: try #require(VersionRule.Base("v3"))) == "3.0.0")
        #expect(VersionRule.exact.constraint(for: try #require(VersionRule.Base("1.2-rc1"))) == "1.2.0-rc1")
    }

    @Test func exactKeepsPreReleaseAndFourPartVersions() throws {
        let four = try #require(VersionRule.Base("v4.2.0.1"))
        #expect(VersionRule.exact.constraint(for: four) == "4.2.0.1")
        let beta = try #require(VersionRule.Base("1.0.0-beta.2"))
        #expect(VersionRule.exact.constraint(for: beta) == "1.0.0-beta.2")
        #expect(VersionRule.patches.constraint(for: beta) == "~1.0.0")
        #expect(
            AddSkillCopy.ruleNote(version: beta.exact)
                == "Written to skills.toml; skills.lock pins 1.0.0-beta.2 exactly.")
    }

    // MARK: - GitHub skill paths

    @Test(.timeLimit(.minutes(1))) func aGithubSkillPathPreviewsTheRepositoryAndAddsTheSkill() async throws {
        let spec = "github:anthropics/skills/pdf"
        let info = DesignFixtures.text("info.package.anthropics-skills", "json")
            .replacingOccurrences(
                of: #""locked": true"#, with: #""locked": false"#)
        // api's skills.toml names anthropics/skills, so the entry is asked: its `source` says whether `add` merges.
        await client.json(.info(.package("anthropics/skills")), in: scope, info)
        let search = search()
        search.query = spec
        await search.searchTask?.value
        await search.infoTask?.value
        #expect(await client.commands == [.info(.package("anthropics/skills"))])
        #expect(search.entryWarning == nil, "a GitHub entry")
        #expect(search.providedSkills.map(\.name) == ["pdf"] && search.chosenSkills == ["pdf"])
        #expect(search.command == .add(spec: spec, repository: nil, adopt: false, rename: [:], skills: []))
        let pinned = try #require(PackageSpec.parse("github:Owner/Repo/skill@v1"))
        #expect(pinned.infoTarget == "github:owner/repo@v1" && pinned.text == "github:Owner/Repo/skill@v1")
        #expect(pinned.skill == "skill")
        #expect(PackageSpec.parse("github:owner/repo")?.infoTarget == "github:owner/repo")
    }

    @Test(.timeLimit(.minutes(1))) func aSkillsShResultPreviewsTheRepository() async {
        let name = "github:anthropics/skills/pdf"
        await client.json(
            .info(.package("github:anthropics/skills")), in: scope,
            #"{"package":"anthropics/skills","skills":[{"name":"pdf"},{"name":"docx"}]}"#)
        let search = search(capabilities: Self.capable)
        search.preload(
            query: "pdf",
            results: .loaded(
                DesignFixtures.decode(
                    SearchDocument.self,
                    json:
                        #"{"results":[{"name":"github:anthropics/skills/pdf","source":"skills.sh","installs":900}],"skills-sh":true}"#
                )))
        search.selection = name
        await search.infoTask?.value
        #expect(search.chosenSkills == ["pdf"])
        #expect(
            search.command == .add(spec: name, repository: nil, adopt: false, rename: [:], skills: []), "no --skill")
    }

    // MARK: - Closing

    @Test(.timeLimit(.minutes(1))) func closingWithinTheDebounceRunsNoSearch() async {
        let search = search(debounce: .milliseconds(200))
        search.query = "jira"
        search.end()
        await search.searchTask?.value
        search.query = "jira triage"
        await search.searchTask?.value
        #expect(await client.commands.isEmpty)
        #expect(search.results == .idle)
    }

    @Test(.timeLimit(.minutes(1))) func closingCancelsThePreviewDownload() async {
        let gate = Gate()
        await client.json(
            .info(.package(Self.jira)), in: scope, #"{"package":"netresearch/agent-jira-skill"}"#, gate: gate)
        let search = search()
        search.selection = Self.jira
        await gate.arrived()
        search.end()
        await gate.open()
        await search.infoTask?.value
        #expect(search.infos.isEmpty && search.infoErrors.isEmpty)
    }

    /// Regression: selecting a result whose preview failed again kept the old error while the new read ran.
    @Test(.timeLimit(.minutes(1))) func reselectingAFailedResultClearsItsError() async {
        await client.script(.info(.package(Self.jira)), in: scope, .error(.noDocument))
        let search = search()
        search.selection = Self.jira
        await search.infoTask?.value
        #expect(search.infoErrors[Self.jira] != nil)
        await client.json(.info(.package(Self.jira)), in: scope, #"{"package":"netresearch/agent-jira-skill"}"#)
        search.selection = nil
        search.selection = Self.jira
        #expect(search.infoErrors[Self.jira] == nil)
        await search.infoTask?.value
        #expect(search.infos[Self.jira] != nil && search.infoErrors[Self.jira] == nil)
    }

    @Test(.timeLimit(.minutes(1))) func theConsentAnswerSurvivesTheNextKeystroke() async throws {
        await client.json(Self.searchJira, in: scope, Self.searchJSON)
        let include = Invocation.Command.search(query: "jira", skillsSh: .include, remember: true)
        let gate = Gate()
        await client.json(
            include, in: scope,
            Self.searchJSON.replacingOccurrences(of: #""skills-sh": null"#, with: #""skills-sh": true"#),
            gate: gate)
        let search = search(debounce: .milliseconds(200))
        search.query = "jira"
        search.retry()
        await search.searchTask?.value
        search.answerConsent(include: true)
        await gate.arrived()
        search.query = "jira t"
        search.end()
        await gate.open()
        await search.consentTask?.value
        #expect(search.skillsSh == .enabled, "the remembered answer ran to the end")
        #expect(await client.commands.contains(include))
    }

    // MARK: - Scope wording

    @Test func personalScopeNamesMySkills() {
        #expect(AddSkillCopy.alreadyIn(["jira-cli"], personal: false) == "Already in this project as jira-cli.")
        #expect(AddSkillCopy.alreadyIn(["jira-cli"], personal: true) == "Already in My Skills as jira-cli.")
        #expect(AddSkillCopy.installedHint(personal: true) == "Already in your personal skills.lock")
        #expect(
            AddSkillCopy.notAllowed("GitHub", personal: true)
                == "GitHub is not an allowed source for your personal skills.")
    }

    @Test func otherProblemsAreNotCalledNotFound() throws {
        let spec = try #require(PackageSpec.parse("acme/lint@^9"))
        let message = AddSkillCopy.previewFailure(
            .failed(code: .problem, message: "no version of acme/lint matches ^9", hint: nil, stderr: ""), spec: spec)
        #expect(
            message.title == "Couldn’t look up acme/lint." && message.reason == "No version of acme/lint matches ^9.")
        let missing = AddSkillCopy.previewFailure(
            .failed(
                code: .problem, message: "package acme/x not found in repositories packagist, acme", hint: nil,
                stderr: ""),
            spec: PackageSpec.parse("acme/x"))
        #expect(missing.title == "Couldn’t find acme/x.")
    }

    // MARK: - Add

    func scriptRefresh() async {
        let skills = ["jira-syntax", "jira-communication"]
            .map {
                AddSkillVisitTests.Added(package: Self.jira, skill: $0, version: "4.2.0")
            }
        await client.json(.status, in: scope, AddSkillVisitTests.status(skills))
        await client.json(.audit, in: scope, ScopeStoreTests.emptyAudit)
        await client.json(.doctor(fix: false), in: scope, ScopeStoreTests.cleanDoctor)
    }

    /// The board's transcript prints no `added` line: the add is worded from the package alone.
    @Test(.timeLimit(.minutes(1))) func addSuccessStaysInTheSheetWithoutAToast() async throws {
        let search = search()
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        let command = try #require(search.command)
        await client.lines(command, in: scope, DesignFixtures.Transcripts.addJira)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let visit = AddSkillVisit(search: search)
        await visit.add(runner: runner)?.value
        #expect(visit.run.phase == .succeeded && runner.toast == nil)
        #expect(visit.status == "Added netresearch/agent-jira-skill" && search.selection == Self.jira)
        #expect(runner.activity.first?.title == "Adding netresearch/agent-jira-skill…")
        await visit.close(runner: runner)?.value
        #expect(runner.toast?.text == "Added netresearch/agent-jira-skill")
        #expect(search.store.selection == "jira-syntax", "the first skill of the add")
    }

    @Test(.timeLimit(.minutes(1))) func addFailureStaysWithTheCLIsHint() async throws {
        let search = search()
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        let command = try #require(search.command)
        await client.script(
            command, in: scope,
            .error(
                .failed(
                    code: .problem, message: "no version of netresearch/agent-jira-skill matches ^9",
                    hint: "run skillcask install", stderr: "")))
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        var closed = false
        await run.start(
            command, title: AddSkillCopy.adding(Self.jira), failure: AddSkillCopy.couldNotAdd(Self.jira),
            outcome: { $0 }, in: search.store, runner: runner, onSuccess: { closed = true }
        )?
        .value
        let failure = try #require(run.failure)
        #expect(!closed && run.canClose && runner.banner == nil)
        #expect(failure.title == "Couldn’t add netresearch/agent-jira-skill.")
        #expect(failure.reason == "No version of netresearch/agent-jira-skill matches ^9.")
        #expect(failure.action == "Sync this project.", "the CLI hint, reworded through ErrorCopy's table")
    }

    @Test(.timeLimit(.minutes(1))) func cancelStopsTheAdd() async throws {
        let search = search()
        search.preload(query: Self.jira, selection: Self.jira, info: AddSkillSamples.jiraInfo)
        let command = try #require(search.command)
        let gate = Gate()
        await client.lines(command, in: scope, [], gate: gate)
        await scriptRefresh()
        let runner = ActionRunner(queue: MutationQueue())
        let run = SheetRun()
        let task = run.start(
            command, title: AddSkillCopy.adding(Self.jira), outcome: { $0 }, in: search.store, runner: runner,
            onSuccess: {})
        await gate.arrived()
        #expect(!run.canClose && run.action?.title == "Adding netresearch/agent-jira-skill…")
        run.cancel()
        await gate.open()
        await task?.value
        #expect(run.failure?.reason == ErrorCopy.cancelled && run.canClose)
    }

    // MARK: - Copy

    @Test func copyFormats() {
        #expect(AddSkillCopy.compact(4100) == "4.1k" && AddSkillCopy.compact(38) == "38")
        #expect(AddSkillCopy.compact(2000) == "2k" && AddSkillCopy.compact(1_500_000) == "1.5M")
        #expect(AddSkillCopy.elapsed(7) == "0:07" && AddSkillCopy.elapsed(75) == "1:15")
        #expect(AddSkillCopy.addButton(skills: 2) == "Add 2 Skills" && AddSkillCopy.addButton(skills: nil) == "Add")
        #expect(
            AddSkillCopy.noResultsBody(sources: ["packagist", "acme"], skillsShOn: false)
                == "in packagist and acme. skills.sh is off; turn it on in Settings › Search to include it.")
        #expect(AddSkillCopy.added(package: "a/b", skills: [], version: nil) == "Added a/b")
    }

    /// The run's output box: the board's 112 pt in the board's sheet (and in Adopt's shorter one), every extra point
    /// of a taller sheet, and one placeholder line until the CLI prints.
    @Test func theOutputBoxKeepsTheBoardsHeightAndGrowsWithTheSheet() {
        #expect(AddSkillProgress.outputHeight(in: AddSkillProgress.boardHeight) == 112)
        #expect(AddSkillProgress.outputHeight(in: 240) == 112, "never smaller")
        #expect(AddSkillProgress.outputHeight(in: AddSkillProgress.boardHeight + 440.6) == 552)
        #expect(AddSkillCopy.waitingForOutput == "Waiting for output…")
    }

    // MARK: - Flow-F2 rules

    /// Flow-F2: "Up to next major (default) / Exact / Latest / Branch". Latest and Branch need `allow-ranges`
    /// (`is_exact`, `manifest::check_constraint`); Branch only for GitHub and git sources (`add_github`, `add_git`).
    @Test func latestAndBranchAreOfferedWhereTheCLIAcceptsThem() throws {
        let base = try #require(VersionRule.Base("4.2.0"))
        #expect(
            VersionRule.options(for: base, allowRanges: true, source: .github, branch: "")
                == [.compatible, .patches, .exact, .latest, .branch("")])
        #expect(
            VersionRule.options(for: base, allowRanges: true, source: .registry, branch: "main")
                == [.compatible, .patches, .exact, .latest])
        #expect(VersionRule.options(for: base, allowRanges: false, source: .git, branch: "main") == [.exact])
        #expect(
            VersionRule.latest.constraint(for: base) == "*" && VersionRule.branch("dev").constraint(for: base) == "dev")
        #expect(AddSkillCopy.ruleLabel(.exact, base: base) == "Exact")
        #expect(AddSkillCopy.ruleLabel(.latest, base: base) == "Latest")
        #expect(AddSkillCopy.ruleLabel(.branch("main"), base: base) == "Branch")
        #expect(
            AddSkillCopy.ruleNote(rule: .branch("main"), version: "4.2.0")
                == "Written to skills.toml; skills.lock pins the branch’s current commit.")
        #expect(
            AddSkillCopy.ruleNote(rule: .latest, version: "4.2.0")
                == "Written to skills.toml; skills.lock pins the version it installs.", "names no version")
        #expect(AddSkillCopy.ruleLabel(.compatible, base: nil) == "As the command-line tool chooses")
    }

    /// The CLI reads the `@` part as a ref only when `Constraint::parse` fails, and `check_constraint` limits the
    /// characters (src/commands.rs 1389–1400, src/manifest.rs `check_constraint`).
    @Test func aBranchNameIsOneTheCLITakesAsARef() {
        // check_constraint's characters, and nothing Constraint::parse reads as a version (src/version.rs atom).
        for good in [
            "main", "dev", "feature/x-1", "release_2", "dev-main", "v-next", "2024-release", "release-1", "1.0-hotfix",
            // The rc number overflows u64, so `parse_partial` fails and the CLI takes it as a ref.
            "v1rc99999999999999999999",
        ] {
            #expect(VersionRule.isValidBranch(good), "\(good)")
        }
        for bad in [
            "", "1.0", "v2", "2024", "x", "1.x", "2-beta1", "1.0-dev", "1.0.0-rc.1",
            // 20 digits that still fit a u64: a version (`x.parse::<u64>()` succeeds).
            "v1rc10000000000000000000", "-a", "/a", "a/", "a..b", "a//b",
            "a b", "*", "ä",
        ] {
            #expect(!VersionRule.isValidBranch(bad), "\(bad)")
        }
    }

    @Test func aGitHubSpecTakesTheBranchAsItsRef() {
        let search = search()
        let spec = "github:acme/jira"
        search.preload(query: spec, selection: spec, info: AddSkillSamples.jiraInfo)
        #expect(search.ruleOptions.last == .branch(""))
        search.rule = .branch("")
        #expect(search.hasBranchProblem && search.command == nil, "the field starts empty; Add waits for a name")
        search.branch = "2024-release"
        #expect(search.effectiveRule == .branch("2024-release") && search.constraint == "2024-release")
        #expect(
            search.command
                == .add(spec: "\(spec)@2024-release", repository: nil, adopt: false, rename: [:], skills: []))
        search.branch = "1.0"
        #expect(search.hasBranchProblem && search.command == nil, "1.0 would be read as a version")
        search.rule = .latest
        #expect(search.command == .add(spec: "\(spec)@*", repository: nil, adopt: false, rename: [:], skills: []))
    }

    /// The toast reads the version `add` locked from its own line, not `info`'s guess (a ref locks a 12-digit sha).
    @Test func theAddToastReadsTheVersionFromTheCLILine() {
        let ref = [OutputLine.stdout(#"added netresearch/agent-jira-skill = "main" (3f2a9c1d0b7e)"#)]
        #expect(
            AddSkillCopy.added(package: Self.jira, skills: ["jira-syntax", "jira-communication"], transcript: ref)
                == "Added jira-syntax and jira-communication (3f2a9c1d0b7e)")
        let tag = [OutputLine.stdout(#"added netresearch/agent-jira-skill = "^4.2" (4.2.0)"#)]
        #expect(
            AddSkillCopy.added(package: Self.jira, skills: ["jira-syntax"], transcript: tag)
                == "Added jira-syntax (4.2.0)")
        #expect(
            AddSkillCopy.added(package: Self.jira, skills: ["jira-syntax"], transcript: []) == "Added \(Self.jira)")
    }
}
