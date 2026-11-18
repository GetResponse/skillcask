import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The detail's Versions tab (S6: Versions and Versions-States boards): the state's callout, the card of
/// Installed / Allowed range / Available in range / Newest overall rows, the collapsible "All known versions"
/// list and the dates footnote. Which rows and callout show is `VersionsContent`; this view only draws.
///
/// The full list needs a network `info --json -- <package>`, so it is loaded only when the list is expanded
/// (never on selection), through `load`, which the store answers from its session cache when it can.
/// Collapsing the list, or leaving the row, cancels the load: it runs in `.task(id:)` keyed on the expanded
/// package. While it runs a spinner and Cancel show; a failure shows its sentence and Retry.
struct VersionsTab: View {
    let content: VersionsContent
    /// The package `load` asks about; expansion is remembered per package, so another row starts collapsed.
    let package: String
    /// `info.versions` from the session cache; nil until loaded.
    let versions: [String]?
    let isLoading: Bool
    let loadError: CLIError?
    let load: () async -> Void
    /// Opens the Review Update sheet for the package (the cooldown callout's "Read the changes…").
    let onReview: () -> Void
    /// Reveals the scope's skills.toml in Finder (the Allowed range row's link).
    let onRevealManifest: () -> Void
    let onEmptyClick: () -> Void

    @State private var expandedPackage: String?
    @State private var attempt = 0
    @State private var showsAll = false

    /// The board's `.vrow` label column, `grid-template-columns: 120px 150px …`.
    static let labelWidth: CGFloat = 120
    /// The version column: Versions-States' 110 pt, since the Versions board's 150 pt wraps the detail sentences
    /// in a 720 pt column.
    static let versionWidth: CGFloat = 110
    /// Rows the open list shows before "N older versions hidden · Show all" (Versions board: five).
    static let visibleVersions = 5

    init(
        content: VersionsContent, package: String, versions: [String]?, isLoading: Bool = false,
        loadError: CLIError? = nil, initiallyExpanded: Bool = false, load: @escaping () async -> Void = {},
        onReview: @escaping () -> Void = {}, onRevealManifest: @escaping () -> Void = {},
        onEmptyClick: @escaping () -> Void = {}
    ) {
        self.content = content
        self.package = package
        self.versions = versions
        self.isLoading = isLoading
        self.loadError = loadError
        self.load = load
        self.onReview = onReview
        self.onRevealManifest = onRevealManifest
        self.onEmptyClick = onEmptyClick
        _expandedPackage = State(initialValue: initiallyExpanded ? package : nil)
    }

    /// The tab over a `ScopeStore`: the model from the selected entry, the scope's policy and targets, and the
    /// package's cached `info` (its `versions-released` dates the rows); the allowed range from the cached package
    /// `info`, else the detail's. "Reveal skills.toml" reveals `manifest` (`AppStore.manifest(of:)`: the personal one
    /// is in the config directory).
    init(
        entry: SkillEntry, store: ScopeStore, manifest: URL, onReview: @escaping () -> Void,
        onEmptyClick: @escaping () -> Void
    ) {
        let package = entry.package ?? entry.id
        let cached = store.packageInfo[package]
        let range = [cached, store.detail?.info].compactMap { $0 }
            .lazy.compactMap { DetailOverviewCopy.allowedRange(why: $0.why) }.first
        let model = VersionsModel(
            entry: entry, policy: store.snapshot?.policy ?? [], allowedRange: range,
            released: VersionsModel.released(in: cached))
        let agents = store.snapshot?.targets?.entries.map(ShellCopy.agentName) ?? []
        self.init(
            content: VersionsContent(
                model: model, versions: cached?.versions, agents: agents, checkedAt: store.snapshot?.checkedAt,
                now: .now),
            package: package, versions: cached?.versions, isLoading: store.loadingPackageInfo.contains(package),
            loadError: store.packageInfoErrors[package], load: { await store.loadPackageInfo(package) },
            onReview: onReview, onRevealManifest: { Workspace.revealManifest(manifest, root: store.scope.root) },
            onEmptyClick: onEmptyClick)
    }

    private var isExpanded: Bool {
        expandedPackage == package
    }

    /// What the load task is keyed on: collapsing or another package cancels it; Retry starts it again.
    private struct LoadKey: Hashable {
        let package: String?
        let attempt: Int
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            column
            ScrollView { column }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Color.surfaceWindow
                .contentShape(Rectangle())
                .onTapGesture(perform: onEmptyClick)
        }
        .task(id: LoadKey(package: expandedPackage, attempt: attempt)) {
            guard isExpanded, versions == nil else { return }
            await load()
        }
    }

    // MARK: - Subviews

    private var column: some View {
        VStack(alignment: .leading, spacing: OverviewTab.sectionGap) {
            if let callout = content.callout {
                MessageStrip(
                    callout.kind, title: callout.title, text: callout.text, monoFragment: callout.mono,
                    symbol: callout.symbol, density: .strip,
                    trailing: callout.link.map { .link($0, action: onReview) })
            }
            if !content.rows.isEmpty {
                rowsCard
            }
            if let footnote = content.footnote {
                quiet(footnote)
            }
            if isExpanded {
                versionsCard
            } else {
                collapsedList
            }
            Spacer(minLength: 0)
            quiet(VersionsCopy.datesFootnote)
        }
        .padding(.horizontal, Size.columnPadding)
        .padding(.top, Spacing.l)
        .padding(.bottom, Size.columnPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rowsCard: some View {
        card {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: 0) {
                ForEach(Array(content.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        hairline
                    }
                    GridRow {
                        Text(row.label)
                            .font(Font.Token.callout)
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        Text(row.version)
                            .font(Font.Token.mono)
                            .foregroundStyle(color(row.tone))
                            .textSelection(.enabled)
                            .frame(width: Self.versionWidth, alignment: .leading)
                        Self.styled(row.detail, monos: row.monos)
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // The trailing column keeps its one line; the detail column wraps instead.
                        trailing(row.trailing)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                    .padding(.vertical, OverviewTab.rowPadding)
                }
            }
        }
    }

    @ViewBuilder private func trailing(_ trailing: VersionsContent.Trailing?) -> some View {
        switch trailing {
        case .quiet(let text):
            Text(text)
                .font(Font.Token.caption)
                .foregroundStyle(Color.textSecondary)
        case .reveal(let title):
            link(title, action: onRevealManifest)
        case nil:
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// Versions-States "All known versions · 12 · Show": one quiet line until expanded.
    private var collapsedList: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.inline) {
            quiet(VersionsCopy.allVersions(count: versions?.count) + RowCopy.separator)
            link(VersionsCopy.show) {
                showsAll = false
                expandedPackage = package
            }
        }
    }

    /// The Versions board's second card: the header, then the list, the spinner, or the failure.
    private var versionsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(VersionsCopy.allVersions(count: versions?.count))
                        .font(Font.Token.calloutSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Spacer(minLength: 0)
                    link(isLoading ? VersionsCopy.cancel : VersionsCopy.hide) { expandedPackage = nil }
                }
                .padding(.vertical, OverviewTab.rowPadding)
                if let versions {
                    versionList(versions)
                } else if let loadError, !isLoading {
                    hairline
                    failure(loadError)
                        .padding(.vertical, OverviewTab.rowPadding)
                } else {
                    hairline
                    Spinner(label: VersionsCopy.loading)
                        .padding(.vertical, OverviewTab.rowPadding)
                }
            }
        }
    }

    private func versionList(_ versions: [String]) -> some View {
        let listed = content.model.listed(versions)
        let shown = showsAll ? listed : Array(listed.prefix(Self.visibleVersions))
        return VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: 0) {
                ForEach(shown) { item in
                    hairline
                    GridRow {
                        Text(item.version)
                            .font(Font.Token.mono)
                            .fontWeight(item.standing == .installed ? .medium : .regular)
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .frame(width: Self.labelWidth, alignment: .leading)
                        Text(VersionsCopy.date(item.released))
                            .font(Font.Token.callout)
                            .foregroundStyle(item.released == nil ? Color.textSecondary : Color.textPrimary)
                            .frame(width: Self.versionWidth, alignment: .leading)
                        Text(VersionsCopy.standing(item.standing))
                            .font(Font.Token.callout)
                            .foregroundStyle(standingColor(item.standing))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, OverviewTab.rowPadding)
                }
            }
            if listed.count > shown.count {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.inline) {
                    quiet(VersionsCopy.hidden(listed.count - shown.count) + RowCopy.separator)
                    link(VersionsCopy.showAll) { showsAll = true }
                }
                .padding(.vertical, Spacing.s)
            }
        }
    }

    private func failure(_ error: CLIError) -> some View {
        MessageStrip(
            .error, title: VersionsCopy.loadFailed, text: ErrorCopy.message(for: error).title, density: .strip,
            trailing: .button(OutcomeCopy.retry) { attempt += 1 })
    }

    // MARK: - Pieces

    /// The boards' bordered card: `padding: 2px 14px`, a hairline between rows (as `OverviewTab`).
    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Size.cardPaddingH)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.l))
            .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Color.separator, lineWidth: Size.hairline))
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(height: Size.hairline)
            .gridCellUnsizedAxes(.horizontal)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Font.Token.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The boards' accent text link (`color: var(--accent); font-weight: 500`).
    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font.Token.calloutMedium)
                .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func color(_ tone: VersionsContent.Tone) -> Color {
        switch tone {
        case .primary: Color.textPrimary
        case .update: Color.statusText(.update)
        case .warning: Color.statusText(.warning)
        case .neutral: Color.statusText(.neutral)
        }
    }

    private func standingColor(_ standing: VersionsModel.Standing) -> Color {
        switch standing {
        case .waiting: Color.statusText(.warning)
        case .installed, .available: Color.textPrimary
        case .outsideRange, .inRange, .belowRange, .older, .unknown: Color.textSecondary
        }
    }

    /// `text` in callout size with each of `monos` (in order, first occurrence after the previous) in small mono.
    static func styled(_ text: String, monos: [String]) -> Text {
        var result = Text("")
        var rest = Substring(text)
        for mono in monos where !mono.isEmpty {
            guard let range = rest.range(of: mono) else { continue }
            result =
                result + Text(rest[..<range.lowerBound]).font(Font.Token.callout)
                + Text(rest[range]).font(Font.Token.monoSmall)
            rest = rest[range.upperBound...]
        }
        return result + Text(rest).font(Font.Token.callout)
    }
}
