import Foundation
import SkillcaskCore
import SkillcaskDomain
import Testing

@testable import SkillcaskUI

/// The Versions tab (S6) per board state over the design fixtures, and the store's network `info <package>`
/// behind "All known versions": loaded only when asked, once per session.
@Suite @MainActor struct VersionsTabTests {
    static let now = Date()

    static func content(
        _ entry: SkillEntry, info: InfoDocument?, snapshot: ScopeSnapshot = DesignFixtures.api, loaded: Bool = false
    ) -> VersionsContent {
        let range = info.flatMap { DetailOverviewCopy.allowedRange(why: $0.why) }
        let model = VersionsModel(entry: entry, policy: snapshot.policy, allowedRange: range)
        return VersionsContent(
            model: model, versions: loaded ? info?.versions : nil, agents: ["Claude Code", "Cursor"],
            checkedAt: now.addingTimeInterval(-240), now: now, timeZone: .gmt)
    }

    static func row(_ content: VersionsContent, _ label: String) -> VersionsContent.Row? {
        content.rows.first { $0.label == label }
    }

    // MARK: - States

    @Test func cooldownShowsTheEligibleDateAndThePolicyAge() throws {
        let content = Self.content(DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo)
        let callout = try #require(content.callout)
        #expect(callout.kind == .warning)
        #expect(callout.symbol == "hourglass")
        #expect(callout.link == "Read the changes…")
        #expect(callout.title == "4.3.0 becomes available on 30 Oct 2026.")
        #expect(
            callout.text
                == "Your minimum release age is 3 d, set in config.toml and enforced by your organisation. It was "
                + "released 28 Oct 2026 at 09:14. Skillcask offers it once it is old enough. An older version in your "
                + "range may be eligible now; Review changes… on the Overview shows what Update would lock.")
        #expect(content.rows.map(\.label) == ["Installed", "Allowed range", "Available in range", "Newest overall"])
        let waiting = try #require(Self.row(content, "Available in range"))
        #expect(waiting.version == "4.3.0")
        #expect(waiting.tone == .warning)
        #expect(waiting.detail == "Released 28 Oct 2026 · eligible 30 Oct 2026 (3 d)")
        #expect(waiting.trailing == .quiet("Waiting"))
        #expect(Self.row(content, "Installed")?.detail == "Release date unknown · in skills.lock")
        #expect(Self.row(content, "Installed")?.trailing == .quiet("Linked into Claude Code, Cursor"))
        #expect(Self.row(content, "Allowed range")?.detail == "From skills.toml · up to the next major")
        #expect(Self.row(content, "Allowed range")?.trailing == .reveal("Reveal skills.toml"))
        #expect(Self.row(content, "Newest overall")?.detail == "Same as above; no major release outside the range")
    }

    @Test func theAllowedRangeRevealsTheManifest() {
        let content = Self.content(DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo)
        #expect(Self.row(content, "Allowed range")?.trailing == .reveal("Reveal skills.toml"))
        #expect(content.rows.filter { $0.trailing == .reveal(ShellCopy.revealManifest) }.count == 1)
    }

    @Test func upToDateSaysTheNewestVersion() throws {
        let content = Self.content(DesignFixtures.commitMessage, info: DesignFixtures.commitMessageInfo)
        let callout = try #require(content.callout)
        #expect(callout.kind == .ok)
        #expect(callout.symbol == nil)
        #expect(callout.link == nil)
        #expect(callout.title == "3.1.0 is the newest version.")
        #expect(callout.text == "Checked 4 min ago.")
        #expect(content.rows.map(\.label) == ["Installed", "Allowed range", "Newest overall"])
        #expect(Self.row(content, "Installed")?.detail == "Released 1 Oct 2026 · in skills.lock")
        #expect(Self.row(content, "Newest overall")?.detail == "Same")
        #expect(content.footnote == nil)
    }

    @Test func withinRangeLeavesTheReviewToTheHeaderStrip() throws {
        let content = Self.content(DesignFixtures.pdf, info: DesignFixtures.pdfInfo, loaded: true)
        #expect(content.callout == nil)
        let available = try #require(Self.row(content, "Available in range"))
        #expect(available.version == "1.4.0")
        #expect(available.tone == .update)
        #expect(available.detail == "Released 24 Oct 2026 · skipped 1.3.0")
        #expect(available.trailing == nil)
        #expect(content.footnote == VersionsCopy.reviewFootnote)
    }

    @Test func withinRangeWithoutTheListNamesNoSkippedVersion() {
        let content = Self.content(DesignFixtures.pdf, info: DesignFixtures.pdfInfo)
        #expect(Self.row(content, "Available in range")?.detail == "Released 24 Oct 2026")
    }

    @Test func majorOutsideIsTextNeverAButton() throws {
        let content = Self.content(DesignFixtures.legacyLint, info: DesignFixtures.legacyLintInfo)
        let callout = try #require(content.callout)
        #expect(callout.kind == .neutral)
        #expect(callout.title == "3.0.0 exists but needs a range change.")
        #expect(callout.mono == "^2.0")
        #expect(callout.text.hasPrefix("Your range ^2.0 in skills.toml stops at the next major."))
        #expect(callout.link == nil)
        #expect(content.rows.allSatisfy { $0.trailing == nil || ["Installed", "Allowed range"].contains($0.label) })
        #expect(Self.row(content, "Available in range")?.detail == "Nothing newer below 3.0")
        let newest = try #require(Self.row(content, "Newest overall"))
        #expect(newest.detail == "Released 15 Oct 2026 · outside ^2.0")
        #expect(newest.monos == ["^2.0"])
        #expect(newest.tone == .neutral)
    }

    @Test func tagMovedShowsTheCalloutAndBothCommits() throws {
        let content = Self.content(DesignFixtures.managedCaveman, info: nil, snapshot: DesignFixtures.apiTagMoved)
        let callout = try #require(content.callout)
        #expect(callout.kind == .warning)
        #expect(
            callout.title
                == "The tag 4.0.1 of your installed version now points at different content than when it was locked.")
        #expect(callout.symbol == "tag.slash")
        #expect(callout.link == nil)
        // The CLI reports the installed version's tag, so the strip is on the Installed row.
        let installed = try #require(Self.row(content, "Installed"))
        #expect(installed.version == "4.0.1" && installed.tone == .warning)
        #expect(installed.detail == "Tag moved · was a81f2c0, now 3fd09e1")
        #expect(installed.monos == ["a81f2c0", "3fd09e1"])
        let row = try #require(Self.row(content, "Available in range"))
        #expect(row.version == "4.1.0" && row.tone == .update)
        #expect(!row.detail.contains("Tag moved") && row.monos.isEmpty)
        #expect(row.trailing == nil)
        #expect(
            content.footnote == "Update stays available but is never the default button while this note is present.")
    }

    @Test func listLabelsAndDates() {
        let model = Self.content(DesignFixtures.jiraCommunication, info: DesignFixtures.jiraPackageInfo).model
        let listed = model.listed(DesignFixtures.jiraPackageInfo.versions)
        #expect(listed.count == 9)
        #expect(VersionsCopy.standing(listed[0].standing, timeZone: .gmt) == "Too new for your policy until 30 Oct")
        #expect(VersionsCopy.date(listed[0].released, timeZone: .gmt) == "28 Oct 2026")
        #expect(VersionsCopy.standing(listed[1].standing) == "Installed")
        #expect(VersionsCopy.date(listed[1].released) == "unknown")
        #expect(VersionsCopy.standing(listed[2].standing) == "Below your range")
        #expect(VersionsCopy.allVersions(count: 9) == "All known versions · 9")
        #expect(VersionsCopy.hidden(4) == "4 older versions hidden")
    }

    // MARK: - Store

    let client = FakeCLIClient()
    let scope = Scope.project(URL(fileURLWithPath: "/tmp/versions-tab-tests"))

    func store() -> ScopeStore {
        ScopeStore(scope: scope, client: client, capabilities: Capabilities(version: Capabilities.minimum)) { _ in
            SkillText.parse("# fake")
        }
    }

    static let packageInfo =
        #"{"package":"acme/s","versions":["1.1.0","1.0.0"],"why":["acme/s: in skills.toml as \"^1.0\""]}"#

    @Test(.timeLimit(.minutes(1))) func expandLoadsOnceAndThenUsesTheCache() async {
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo)
        let store = store()
        #expect(store.packageInfo.isEmpty)
        await store.loadPackageInfo("acme/s")
        await store.loadPackageInfo("acme/s")
        let infoCalls = await client.commands.filter { $0 == .info(.package("acme/s")) }
        #expect(infoCalls.count == 1)
        #expect(store.packageInfo["acme/s"]?.versions == ["1.1.0", "1.0.0"])
        #expect(store.loadingPackageInfo.isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aSecondExpandWhileLoadingRunsNothing() async {
        let slow = Gate()
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo, gate: slow)
        let store = store()
        let first = Task { await store.loadPackageInfo("acme/s") }
        await slow.arrived()
        #expect(store.loadingPackageInfo == ["acme/s"])
        let second = Task { await store.loadPackageInfo("acme/s") }
        await slow.open()
        await first.value
        await second.value
        #expect(await client.commands.count == 1)
        #expect(store.packageInfo["acme/s"] != nil)
    }

    @Test(.timeLimit(.minutes(1))) func collapsingCancelsTheLoadAndKeepsNothing() async {
        let slow = Gate()
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo, gate: slow)
        let store = store()
        let load = Task { await store.loadPackageInfo("acme/s") }
        await slow.arrived()
        #expect(store.loadingPackageInfo == ["acme/s"])
        load.cancel()
        await slow.open()
        await load.value
        #expect(await client.commands == [.info(.package("acme/s"))])
        #expect(store.packageInfoErrors["acme/s"] == nil)
        #expect(store.packageInfo["acme/s"] == nil)
        #expect(store.loadingPackageInfo.isEmpty)
    }

    /// Collapse during the load, expand again before the cancelled command returns: the second expand waits for
    /// the cancelled run and then asks itself, so the list ends loaded, never on a spinner with nothing loading.
    @Test(.timeLimit(.minutes(1))) func reExpandingDuringACancelledLoadEndsLoaded() async {
        let slow = Gate()
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo, gate: slow)
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo)
        let store = store()
        let collapsed = Task { await store.loadPackageInfo("acme/s") }
        await slow.arrived()
        collapsed.cancel()
        let reExpanded = Task { await store.loadPackageInfo("acme/s") }
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(store.loadingPackageInfo == ["acme/s"])
        await slow.open()
        await collapsed.value
        await reExpanded.value
        #expect(store.packageInfo["acme/s"]?.versions == ["1.1.0", "1.0.0"])
        #expect(store.packageInfoErrors["acme/s"] == nil)
        #expect(store.loadingPackageInfo.isEmpty)
        #expect(await client.commands.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func aWaitingExpandThatIsCancelledReturns() async {
        let slow = Gate()
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo, gate: slow)
        let store = store()
        let first = Task { await store.loadPackageInfo("acme/s") }
        await slow.arrived()
        let waiting = Task { await store.loadPackageInfo("acme/s") }
        for _ in 0..<10 {
            await Task.yield()
        }
        waiting.cancel()
        await waiting.value
        #expect(store.loadingPackageInfo == ["acme/s"])
        await slow.open()
        await first.value
        #expect(store.packageInfo["acme/s"] != nil)
        #expect(await client.commands.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aFailureIsKeptAndRetryAsksAgain() async {
        let offline = CLIError.failed(code: .network, message: "packagist did not answer.", hint: nil, stderr: "")
        await client.script(.info(.package("acme/s")), in: scope, .error(offline))
        await client.json(.info(.package("acme/s")), in: scope, Self.packageInfo)
        let store = store()
        await store.loadPackageInfo("acme/s")
        #expect(store.packageInfoErrors["acme/s"] == offline)
        #expect(store.packageInfo["acme/s"] == nil)
        await store.loadPackageInfo("acme/s")
        #expect(store.packageInfoErrors["acme/s"] == nil)
        #expect(store.packageInfo["acme/s"] != nil)
        #expect(await client.commands.count == 2)
    }

    @Test(.timeLimit(.minutes(1))) func selectingARowNeverRunsTheNetworkInfo() async {
        await client.json(.info(.skill("pdf")), in: scope, #"{"skill":"pdf","kind":"package","path":"x","from":"y"}"#)
        let store = store()
        store.preload(snapshot: DesignFixtures.api)
        await store.select("pdf")
        #expect(await client.commands == [.info(.skill("pdf"))])
    }
}
