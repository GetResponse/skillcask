import SkillcaskCore
import Testing

@testable import SkillcaskDomain

/// The three sort orders of the S2 note over the sample snapshot, and the typed audit rules and policy rows.
@Suite struct SortOrderTests {
    let entries: [SkillEntry]

    init() throws {
        entries = try Sample.snapshot().entries
    }

    @Test func nameIsAlphabetical() {
        #expect(
            SortOrder.name.apply(entries).map(\.name) == [
                "acme/gone", "d", "jira-communication", "jira-syntax", "mine", "notes", "z",
            ])
    }

    @Test func stateIsWorstFirstThenNameAndMatchesTheFilter() {
        let sorted = SortOrder.state.apply(entries)
        #expect(sorted.map(\.name) == ["acme/gone", "jira-syntax", "notes", "z", "jira-communication", "d", "mine"])
        #expect(sorted == Filter.all.apply(entries))
        let severities = sorted.map(\.health.severity)
        #expect(severities == severities.sorted(by: >))
    }

    @Test func sourceGroupsByKindThenName() {
        // At 0.9.4 `status` prints no `source`, so only the adopt spec (z → GitHub), the project skill (notes)
        // and the hand-written skill (mine) have a kind; the four package rows have none and sort last, by name.
        let sorted = SortOrder.source.apply(entries).map(\.name)
        #expect(sorted == ["z", "notes", "mine", "acme/gone", "d", "jira-communication", "jira-syntax"])
        #expect(SortOrder.sourceRank(of: entries[3]) == (1, ""))
        #expect(SortOrder.sourceRank(of: entries[0]) == (7, ""))
    }

    @Test func findingKindsAreTyped() throws {
        #expect(FindingKind(rule: "modified") == .modified && !FindingKind(rule: "modified").isTextFinding)
        #expect(FindingKind(rule: "risky-pattern") == .riskyPattern)
        #expect(FindingKind(rule: "invisible-character") == .invisibleCharacter)
        #expect(FindingKind(rule: "something-new") == .other("something-new"))
        #expect(FindingKind(rule: "something-new").isTextFinding)
        let findings = try Sample.decode(AuditDocument.self, Sample.audit).skills.flatMap(\.findings)
        #expect(findings.map(\.isModified) == [true, false])
        #expect(DiffFlag.Kind(rule: "modified") == nil && DiffFlag.Kind(rule: "risky-pattern") == .risky)
    }

    @Test func policyRowsKnowTheirKindAndOrigin() throws {
        let rows = try Sample.snapshot().policy
        #expect(rows.map(\.kind) == [.minReleaseAge, .allowRanges])
        #expect(rows.map(\.isEnforced) == [false, false] && rows.map(\.origin) == ["config.toml", "skills.toml"])
        let enforced = try Sample.decode(
            StatusDocument.self,
            #"{"ok":true,"entries":[],"policy":{"allow-sources":{"from":"config.toml, enforced","value":["packagist","acme"]},"x-new":{"from":"env","value":1}}}"#
        )
        let snapshot = ScopeSnapshot(status: enforced, audit: nil, doctor: nil, outdated: nil)
        #expect(snapshot.policy.map(\.kind) == [.allowSources, .other("x-new")])
        #expect(snapshot.policy[0].isAllowedSources && snapshot.policy[0].isEnforced)
        #expect(snapshot.policy[0].origin == "config.toml" && snapshot.policy[1].origin == "env")
        let system = try Sample.decode(
            StatusDocument.self,
            #"{"ok":true,"entries":[],"policy":{"min-release-age":{"from":"system config.toml, enforced","value":"3d"}}}"#
        )
        let row = ScopeSnapshot(status: system, audit: nil, doctor: nil, outdated: nil).policy[0]
        #expect(row.isEnforced && row.origin == "system config.toml")
    }
}
