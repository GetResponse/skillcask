import SkillcaskDomain
import SwiftUI

extension PreviewRegistry {
    /// The six Overview cards of the api scope in the detail column's two-column grid (`cards`, Health with
    /// the error border), the Overview-States Healthy variant of the website scope (`collapsed`: Health, Updates
    /// and Security as one line each, nothing coloured on a border) and the Components board's "Overview card"
    /// region (`variants`: the board's two cards, error and default, plus a collapsed one-line card the board does
    /// not draw there, added for coverage).
    ///
    /// The card bodies are samples quoting the boards; the real doctor lines, update rows and tables are the
    /// screen's. The grid gap is `Spacing.cardGap` (10, Overview-States) where `Overview.dc.html` draws 12.
    static let cards: [Entry] = [
        Entry(id: "P2-4", state: "cards", size: CGSize(width: 700, height: 760)) { AnyView(CardsSample()) },
        Entry(id: "P2-4", state: "collapsed", size: CGSize(width: 600, height: 250)) {
            AnyView(CollapsedSample())
        },
        Entry(id: "P2-4", state: "variants", size: CGSize(width: 560, height: 330)) { AnyView(VariantsSample()) },
    ]
}

/// The two-column card grid on the grouped surface, as the Overview's detail column lays it out.
private struct CardGrid<Content: View>: View {
    let padding: EdgeInsets
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Spacing.cardGap) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surfaceGrouped)
    }
}

/// One row of two cards: both as tall as the taller, as the boards' CSS grid stretches them.
private struct CardRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.cardGap) {
            content
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// `Overview.dc.html`: api, 14 skills, 3 need sync. Health has the error border and its two buttons; Updates and
/// Security keep the separator with the dot carrying the colour; Sources, Policy and Agents have no dot.
private struct CardsSample: View {
    var body: some View {
        CardGrid(padding: EdgeInsets(top: Spacing.l, leading: Spacing.xxl, bottom: Spacing.l, trailing: Spacing.xxl)) {
            CardRow {
                health.cell()
                updates.cell()
            }
            CardRow {
                security.cell()
                sources.cell()
            }
            CardRow {
                policy.cell()
                agents.cell()
            }
        }
    }

    private var health: some View {
        CardContainer(title: "Health", status: "2 problems", severity: .error, onTitleTap: openList) {
            HStack(spacing: Spacing.inline) {
                Button("Repair") {}.buttonStyle(.bordered)
                Button("Sync") {}.buttonStyle(.borderedProminent).tint(Color.accent)
            }
            .controlSize(.small)
        } content: {
            CardLine(symbol: "xmark.circle", severity: .error) {
                Text(".claude/skills/pdf").font(Font.Token.monoSmall)
                Text("link points elsewhere")
            } trailing: {
                Text("Repair fixes this")
            }
            CardLine(symbol: "xmark.circle", severity: .error) {
                Text("jira-syntax").font(Font.Token.calloutMedium)
                Text("is in ") + Text("skills.lock").font(Font.Token.monoSmall) + Text(" but not installed")
            } trailing: {
                Text("Sync fixes this")
            }
            CardLine(symbol: "chevron.down", severity: nil) {
                Text("6 checks passed").foregroundStyle(Color.textSecondary)
            }
            Footnote(
                "Repair fixes links, the git index and .gitignore. It downloads nothing. Sync installs exactly what skills.lock pins."
            )
        }
    }

    private var updates: some View {
        CardContainer(title: "Updates", status: "2 available", severity: .update, onTitleTap: openList) {
            Button("Review All…") {}.buttonStyle(.bordered).controlSize(.small)
        } content: {
            updateRow(name: "pdf", from: "1.2.0", to: "1.4.0")
            updateRow(name: "review-pr", from: "2.1.0", to: "2.2.0")
            CardLine(dot: .warning) {
                Text(
                    "jira-syntax, jira-communication: 4.3.0 becomes available on 30 Oct 2026 (minimum release age 72 h)."
                )
                .foregroundStyle(Color.textSecondary)
            }
            CardLine(dot: .neutral) {
                Text("legacy-lint: 3.0.0 exists but needs a range change.").foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func updateRow(name: String, from: String, to: String) -> some View {
        HStack(spacing: Spacing.s) {
            Text(name).font(Font.Token.calloutMedium).lineLimit(1)
            Text(Labels.versionTransition(from: from, to: to)).font(Font.Token.monoSmall).fixedSize()
            Spacer(minLength: Spacing.s)
            AccentLink("Review changes…").fixedSize()
        }
        .font(Font.Token.callout)
        .foregroundStyle(Color.textPrimary)
    }

    private var security: some View {
        CardContainer(
            title: "Security", status: "1 changed on disk, 2 findings", severity: .warning, onTitleTap: openList
        ) {
            AccentLink("Show in list")
        } content: {
            CardLine(symbol: "doc.badge.ellipsis", severity: .error) {
                Text("deploy-checklist").font(Font.Token.calloutMedium)
                Text("differs from the version in the lock")
            }
            CardLine(symbol: "exclamationmark.triangle", severity: .warning) {
                Text("my-notes").font(Font.Token.calloutMedium)
                Text("asks an agent to download and run a script (line 12)")
            }
            CardLine(symbol: "exclamationmark.triangle", severity: .warning) {
                Text("my-notes").font(Font.Token.calloutMedium)
                Text("contains an invisible character (line 3)")
            }
        }
    }

    private var sources: some View {
        CardContainer(title: "Sources") {
            SampleTable(header: ["Name", "Type", "Address", "Policy"]) {
                ForEach(DesignFixtures.api.repositories, id: \.name) { repository in
                    CardRow {
                        Text(repository.name).font(Font.Token.monoSmall)
                        Text(typeName(repository.type))
                        Text(host(repository.url)).font(Font.Token.monoSmall).foregroundStyle(Color.textSecondary)
                        Text(repository.allowed ? "Allowed" : "Blocked")
                            .font(Font.Token.calloutMedium)
                            .foregroundStyle(Color.statusText(repository.allowed ? .ok : .warning))
                    }
                }
            }
            Footnote(
                "GitHub is blocked by Allowed sources, set in config.toml by your organisation. Skills from it stay installed but cannot be added or updated here."
            )
        }
    }

    private var policy: some View {
        CardContainer(title: "Policy") {
            AccentLink("Open config.toml")
        } content: {
            SampleTable(header: ["Setting", "Value", "Set in"]) {
                CardRow {
                    Text("Minimum release age")
                    Text("72 h")
                    enforced("config.toml")
                }
                CardRow {
                    Text("Allowed sources")
                    Text("packagist, acme").font(Font.Token.monoSmall)
                    enforced("config.toml")
                }
                CardRow {
                    Text("Ranges allowed")
                    Text("Yes")
                    Text("skills.toml").font(Font.Token.monoSmall)
                }
            }
            Footnote("“Enforced” means your organisation set it; the project cannot override it.")
        }
    }

    private func enforced(_ file: String) -> Text {
        Text(file).font(Font.Token.monoSmall) + Text(CardCopy.separator)
            + Text(OverviewCopy.enforced).foregroundStyle(Color.statusText(.warning))
    }

    private var agents: some View {
        CardContainer(title: "Agents") {
            SampleTable(header: ["Agent", "Directory", "Set in"]) {
                ForEach(Array(agentRows.enumerated()), id: \.offset) { row in
                    CardRow {
                        Text(row.element.name).font(Font.Token.calloutMedium)
                        Text(row.element.directory).font(Font.Token.monoSmall).foregroundStyle(Color.textSecondary)
                        Text(row.element.from).font(Font.Token.monoSmall)
                    }
                }
            }
            Footnote("14 skills are linked into both. One Claude Code link is wrong — see Health.")
        }
    }

    /// The api scope's targets with their directories (Cursor reads the store, D29).
    private var agentRows: [(name: String, directory: String, from: String)] {
        let from = DesignFixtures.api.targets?.from ?? ""
        return AgentsCard.targets(DesignFixtures.agentIndex(DesignFixtures.api)).map { ($0.agent, $0.directory, from) }
    }

    private func typeName(_ type: String) -> String {
        switch type {
        case "composer": "Packagist"
        case "github": "GitHub"
        default: "Custom repository"
        }
    }

    private func host(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let path = components.path == "/" ? "" : components.path
        return host.replacingOccurrences(of: "repo.", with: "").replacingOccurrences(of: "api.", with: "") + path
    }
}

/// `Overview-States.dc.html` Healthy: website, 3 skills, all match the lock. Three one-line cards, three short
/// bodies, no border in a status colour.
private struct CollapsedSample: View {
    var body: some View {
        CardGrid(padding: EdgeInsets(top: Spacing.l, leading: Spacing.xl, bottom: Spacing.l, trailing: Spacing.xl)) {
            CardRow {
                CardContainer(
                    title: "Health", status: "all good", severity: .ok, summary: "8 checks passed", isCollapsed: true,
                    onTitleTap: openList
                ) {
                    EmptyView()
                }
                .cell()
                CardContainer(
                    title: "Updates", status: "none", severity: .ok, summary: "Everything is current",
                    isCollapsed: true,
                    onTitleTap: openList
                ) {
                    EmptyView()
                }
                .cell()
            }
            CardRow {
                CardContainer(
                    title: "Security", status: "no findings", severity: .ok, summary: "Nothing changed on disk",
                    isCollapsed: true, onTitleTap: openList
                ) {
                    EmptyView()
                }
                .cell()
                CardContainer(title: "Sources") {
                    ForEach(DesignFixtures.website.repositories, id: \.name) { repository in
                        HStack(spacing: Spacing.s) {
                            Text(repository.name).font(Font.Token.monoSmall).foregroundStyle(Color.textPrimary)
                            Text(repository.allowed ? "Allowed" : "Blocked")
                                .font(Font.Token.calloutMedium)
                                .foregroundStyle(Color.statusText(repository.allowed ? .ok : .warning))
                        }
                    }
                }
                .cell()
            }
            CardRow {
                CardContainer(title: "Policy") {
                    policyLine("Minimum release age", value: "0 h")
                    policyLine("Allowed sources", value: "any")
                }
                .cell()
                CardContainer(title: "Agents") {
                    HStack(spacing: Spacing.s) {
                        Text("Claude Code").font(Font.Token.calloutMedium).foregroundStyle(Color.textPrimary)
                        Text(DesignFixtures.website.targets?.dirs.first ?? "")
                            .font(Font.Token.monoSmall)
                            .foregroundStyle(Color.textSecondary)
                        Spacer(minLength: Spacing.s)
                        Text(DesignFixtures.website.targets?.from ?? "")
                            .font(Font.Token.monoSmall)
                            .foregroundStyle(Color.textPrimary)
                    }
                }
                .cell()
            }
        }
    }

    private func policyLine(_ setting: String, value: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(setting).font(Font.Token.callout)
            Text(value).font(Font.Token.calloutSemibold)
            Text("default").font(Font.Token.caption).foregroundStyle(Color.textSecondary)
        }
        .foregroundStyle(Color.textPrimary)
    }
}

/// The Components board's "Overview card" region: the error card with actions, the default card with a
/// summary, and the collapsed one-line card, stacked on the grouped surface.
private struct VariantsSample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            Text("Overview card")
                .font(Font.Token.bodyEmphasis)
                .foregroundStyle(Color.textPrimary)
            CardContainer(title: "Health", status: "2 problems", severity: .error, onTitleTap: openList) {
                HStack(spacing: Spacing.inline) {
                    Button("Repair") {}.buttonStyle(.bordered)
                    Button("Sync") {}.buttonStyle(.borderedProminent).tint(Color.accent)
                }
                .controlSize(.small)
            } content: {
                CardLine(symbol: "xmark.circle", severity: .error) {
                    Text(".claude/skills/pdf").font(Font.Token.monoSmall)
                    Text("link points elsewhere")
                } trailing: {
                    Text("Repair fixes this")
                }
                CardLine(symbol: "chevron.down", severity: nil) {
                    Text("6 checks passed").foregroundStyle(Color.textSecondary)
                }
            }
            CardContainer(
                title: "Health", status: "all good", severity: .ok, summary: "Repaired 2 items just now",
                onTitleTap: openList
            ) {
                CardLine(symbol: "chevron.down", severity: nil) {
                    Text("8 checks passed").foregroundStyle(Color.textSecondary)
                }
            }
            CardContainer(
                title: "Health", status: "all good", severity: .ok, summary: "8 checks passed", isCollapsed: true,
                onTitleTap: openList
            ) {
                Text("never built")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.surfaceGrouped)
    }
}

extension View {
    /// A grid cell as the boards' CSS grid lays it out: the card stretches to its row's height, content at the top.
    fileprivate func cell() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One `.line` of a card body: a 14 px glyph in a status text colour or an 8 pt dot, the words in callout, an
/// optional quiet trailing note.
private struct CardLine<Words: View, Trailing: View>: View {
    let glyph: Glyph
    @ViewBuilder let words: Words
    @ViewBuilder let trailing: Trailing

    enum Glyph {
        case symbol(String, Severity?)
        case dot(Severity)
    }

    init(symbol: String, severity: Severity?, @ViewBuilder words: () -> Words, @ViewBuilder trailing: () -> Trailing) {
        glyph = .symbol(symbol, severity)
        self.words = words()
        self.trailing = trailing()
    }

    init(dot: Severity, @ViewBuilder words: () -> Words, @ViewBuilder trailing: () -> Trailing) {
        glyph = .dot(dot)
        self.words = words()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            switch glyph {
            case .symbol(let name, let severity):
                Image(systemName: name)
                    .font(Font.Token.calloutMedium)
                    .foregroundStyle(severity.map(Color.statusText) ?? Color.textSecondary)
            case .dot(let severity):
                StatusDot(severity)
            }
            words
            Spacer(minLength: Spacing.s)
            trailing
                .font(Font.Token.caption)
                .foregroundStyle(Color.textSecondary)
        }
        .font(Font.Token.callout)
        .foregroundStyle(Color.textPrimary)
    }
}

extension CardLine where Trailing == EmptyView {
    init(symbol: String, severity: Severity?, @ViewBuilder words: () -> Words) {
        self.init(symbol: symbol, severity: severity, words: words) { EmptyView() }
    }

    init(dot: Severity, @ViewBuilder words: () -> Words) {
        self.init(dot: dot, words: words) { EmptyView() }
    }
}

/// The board's 11 pt secondary footnote under a card body.
private struct Footnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(Font.Token.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The board's 12 pt medium link in the accent colour.
private struct AccentLink: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Button(title) {}
            .buttonStyle(.plain)
            .font(Font.Token.calloutMedium)
            .foregroundStyle(Color.accent)
    }
}

/// A card table: a header row in secondary medium, then the rows, separated by hairlines as the board's
/// `border-top: 1px solid var(--sep)`.
private struct SampleTable<Rows: View>: View {
    let header: [String]
    @ViewBuilder let rows: Rows

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: Spacing.xs) {
            CardRow {
                ForEach(header, id: \.self) { title in
                    Text(title).font(Font.Token.calloutMedium).foregroundStyle(Color.textSecondary)
                }
            }
            Divider().overlay(Color.separator)
            rows
        }
        .font(Font.Token.callout)
        .foregroundStyle(Color.textPrimary)
    }
}

/// The title tap of a sample card: the screen opens the filtered list, a sample does nothing.
private func openList() {}
