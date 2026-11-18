import Foundation
import SkillcaskDomain
import SwiftUI

/// The detail column's header (Main board "Skill detail", Detail-States): the state line, the name with its
/// mono version, the package with its source pill, the description, the actions on the right, the section
/// tabs on a hairline, and the blue update strip under them. Which controls show is `DetailActions.resolve`;
/// this view only draws. Buttons and the tabs are system controls; the dot and the pill are the reused
/// `StatusLabel` and `Pill`.
///
/// Declared deviations from the boards: the version beside the name is `Font.Token.mono` (12 pt) where the
/// board draws 14 px mono, because no 14 pt token exists; the Versions tab carries no count badge (see
/// `DetailTabs`, Q9).
public struct DetailHeader: View {
    public let entry: SkillEntry
    public let isOffline: Bool
    @Binding public var selectedTab: DetailTab
    /// The skills that require a dependency ("Required by caveman"), from `ScopeSnapshot.requirerSkills(of:)`;
    /// nil falls back to the package names of the entry's `via` list.
    public let requiredBy: [String]?
    /// The constraint the strip quotes (`^1.2`, from `info`'s `why` via `DetailOverviewCopy.allowedRange`); nil
    /// leaves it out.
    public let allowedRange: String?
    /// The day the strip's "3 days ago" counts to; previews and tests pin it.
    public let now: Date
    public let onUpdate: () -> Void
    public let onAdopt: () -> Void
    public let onRemove: () -> Void
    public let onReviewChanges: () -> Void

    public init(
        entry: SkillEntry, isOffline: Bool = false, selectedTab: Binding<DetailTab>, requiredBy: [String]? = nil,
        allowedRange: String? = nil, now: Date = .now, onUpdate: @escaping () -> Void = {},
        onAdopt: @escaping () -> Void = {},
        onRemove: @escaping () -> Void = {}, onReviewChanges: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.isOffline = isOffline
        _selectedTab = selectedTab
        self.requiredBy = requiredBy
        self.allowedRange = allowedRange
        self.now = now
        self.onUpdate = onUpdate
        self.onAdopt = onAdopt
        self.onRemove = onRemove
        self.onReviewChanges = onReviewChanges
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.l) {
                    identity
                    Spacer(minLength: 0)
                    actionRow
                        .padding(.top, Spacing.xxl)
                }
                DetailTabs(selection: $selectedTab, tabs: DetailTabs.tabs(for: entry))
            }
            .padding(.top, Spacing.xl)
            .padding(.horizontal, Size.columnPadding)
            .padding(.bottom, Spacing.m)
            Rectangle()
                .fill(Color.separator)
                .frame(height: Size.hairline)
            if actions.showsStrip, let target = DetailActions.updateTarget(of: entry) {
                updateStrip(to: target)
                    .padding(.horizontal, Size.columnPadding)
                    .padding(.top, Spacing.l)
            }
        }
        .background(Color.surfaceWindow)
    }

    // MARK: - Derived

    private var actions: DetailActions {
        DetailActions.resolve(entry, offline: isOffline)
    }

    /// The health the state line states: `HealthMapping.stateHealth` (state and update; findings only when one
    /// is `modified`), so a project skill with findings still reads "Project skill" (S3 note).
    nonisolated static func stateHealth(for entry: SkillEntry) -> Health {
        HealthMapping.stateHealth(state: entry.state, update: entry.update, findings: entry.findings)
    }

    private var stateFont: Font {
        Font.Token.calloutSemibold
    }

    // MARK: - Subviews

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            stateLine
            HStack(alignment: .firstTextBaseline, spacing: Spacing.cardGap) {
                Text(entry.name)
                    .font(Font.Token.title)
                    .tracking(Font.Token.titleTracking)
                    .foregroundStyle(Color.textPrimary)
                if let version = entry.version {
                    // Board: 14 px mono; `Font.Token.mono` (12 pt) is the nearest token.
                    Text(version)
                        .font(Font.Token.mono)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            packageLine
            if let description = entry.description {
                Text(description)
                    .font(Font.Token.body)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The dot and its words: `Required by caveman` for a healthy dependency (the requiring skills when the
    /// caller resolved them, else the `via` package names), `Update available` for a row with an update (the
    /// versions sit beside the name and on the button), else the `Health` label.
    private var stateLine: StatusLabel {
        let health = Self.stateHealth(for: entry)
        if case .dependency(_, let via) = entry.kind, health.severity <= .ok {
            let requirers = requiredBy.flatMap { $0.isEmpty ? nil : $0 } ?? via
            return StatusLabel(.neutral, Labels.requiredBy(requirers), font: stateFont)
        }
        if case .updateAvailable = health {
            return StatusLabel(.update, DetailCopy.updateAvailable, font: stateFont)
        }
        return StatusLabel(health, font: stateFont)
    }

    /// The third line: the package name with its source pill, the path of a project or local skill
    /// (`.skills/my-notes`, Detail-States) with its kind pill, or "No package recorded" for a not managed skill
    /// without a source.
    ///
    /// Board/note conflict: the S3 note hides the package + source pill for project and local skills, while
    /// Detail-States draws a "Project" pill beside the path. The board is followed: the kind pill ("Project",
    /// "Local") stands beside the path, no source pill is drawn (`DetailActions.showsSourcePill` stays false).
    @ViewBuilder private var packageLine: some View {
        if actions.showsPath, let path = entry.path {
            HStack(spacing: Spacing.s) {
                Text(path)
                    .font(Font.Token.mono)
                    .foregroundStyle(Color.textSecondary)
                if let kind = SourceKind.kind(of: entry) {
                    Pill(source: kind)
                }
            }
        } else if let package = DetailActions.packageText(of: entry) {
            HStack(spacing: Spacing.s) {
                Text(package)
                    .font(Font.Token.mono)
                    .foregroundStyle(Color.textSecondary)
                if actions.showsSourcePill, let source = SourceKind.kind(of: entry) {
                    Pill(source: source)
                }
            }
        } else if entry.isNotManaged {
            Text(DetailCopy.noPackageRecorded)
                .font(Font.Token.callout)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// The primary button takes the Iris accent token (Rationale: "Iris is used for primary buttons"); selection
    /// elsewhere stays the system accent, so only buttons are tinted.
    private var actionRow: some View {
        HStack(spacing: Spacing.s) {
            switch actions.primary {
            case .update(let target):
                Button(action: onUpdate) {
                    Text(DetailCopy.update(to: target)).fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
            case .reviewChanges:
                Button(DetailCopy.reviewChanges, action: onReviewChanges)
                    .buttonStyle(.bordered)
            case .adopt:
                Button(DetailCopy.adopt, action: onAdopt)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accent)
            case .upToDate:
                quiet(DetailCopy.upToDate)
            case .updatesUnknown:
                quiet(DetailCopy.updatesUnknown)
            case nil:
                EmptyView()
            }
            if actions.showsEditNote {
                quiet(DetailCopy.editInRepository)
            }
            if actions.showsRemove {
                Button(action: onRemove) {
                    Text(DetailCopy.remove).foregroundStyle(Color.statusErrorText)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// The 12 pt secondary text that sits where a button would be.
    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Font.Token.callout)
            .foregroundStyle(Color.textSecondary)
    }

    private func updateStrip(to target: String) -> some View {
        HStack(spacing: Spacing.cardGap) {
            Image(systemName: "arrow.down.circle")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Size.iconSidebar, height: Size.iconSidebar)
                .foregroundStyle(Color.statusUpdateText)
                .accessibilityHidden(true)
            stripText(to: target)
                .font(Font.Token.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            Button(action: onReviewChanges) {
                Text(DetailCopy.reviewChanges)
                    .font(Font.Token.bodyEmphasis)
                    .foregroundStyle(Color.statusUpdateText)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, Spacing.cardGap)
        .padding(.horizontal, Spacing.m)
        .background(Color.statusUpdateTint, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
    }

    private func stripText(to target: String) -> Text {
        var text =
            Text(DetailCopy.available(target)).fontWeight(.semibold) + Text(verbatim: " ")
            + FailureBanner.styled(DetailCopy.insideRange(allowedRange), fragment: allowedRange, font: Font.Token.body)
        if let released = Self.targetReleased(entry.update) {
            text = text + Text(verbatim: " ") + Text(DetailCopy.released(released, now: now))
        }
        return text
    }

    /// When the strip's target (`DetailActions.updateTarget`, which is `within`) was released: `within-released`
    /// (D67), else the old `released` key, which dates `latest`, only when `within` is `latest`; nil otherwise.
    nonisolated static func targetReleased(_ update: Update?) -> Date? {
        guard let update else { return nil }
        if let date = update.withinReleased {
            return date
        }
        return update.within != nil && update.within == update.latest ? update.released : nil
    }
}

#Preview("DetailHeader, light") {
    @Previewable @State var tab = DetailTab.overview
    DetailHeader(entry: DesignFixtures.pdf, selectedTab: $tab)
        .frame(width: 600)
}

#Preview("DetailHeader, dark") {
    @Previewable @State var tab = DetailTab.overview
    DetailHeader(
        entry: DesignFixtures.safeRefactor, selectedTab: $tab,
        requiredBy: DesignFixtures.api.requirerSkills(of: DesignFixtures.safeRefactor)
    )
    .frame(width: 600)
    .preferredColorScheme(.dark)
}
