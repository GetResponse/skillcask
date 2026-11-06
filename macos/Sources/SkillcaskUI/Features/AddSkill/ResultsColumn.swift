import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The Add Skill sheet's left column (AddSkill board, 440 pt; up to 520 in a wider sheet): the skills.sh consent
/// card once, then the results of the header's source filter in a system `List` whose selection is the preview's, or
/// what stands in for them: the idle hint, the spinner, the network failure with Retry, "No results", "No results
/// from <source>" with Show All, or the note that a typed source skips search (AddSkill-States).
struct ResultsColumn: View {
    @Bindable var search: SearchStore

    /// The board's results column width, and the column's width up to a sheet `width / widthShare` (1100 pt) wide.
    nonisolated static let width: CGFloat = 440
    /// The widest the column gets, from a 1300 pt sheet on.
    nonisolated static let maxWidth: CGFloat = 520
    /// The column's share of a sheet wider than 1100 pt.
    nonisolated static let widthShare: CGFloat = 0.4

    /// The column's width in a sheet `sheetWidth` wide: 440 up to 1100, then 40 % of the sheet up to 520, in whole
    /// points.
    nonisolated static func width(in sheetWidth: CGFloat) -> CGFloat {
        min(maxWidth, max(width, (sheetWidth * widthShare).rounded(.down)))
    }
    /// A result from a repository the policy blocks, and the header's blocked pill (`opacity: 0.55`).
    static let blockedOpacity = 0.55

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.showsConsent {
                ConsentCard(
                    onDecline: { search.answerConsent(include: false) },
                    onAccept: { search.answerConsent(include: true) }
                )
                .padding([.horizontal, .top], Spacing.cardGap)
                .padding(.bottom, Spacing.xs)
            }
            content
        }
        // `AddSkillColumns` proposes the width; the column takes exactly that.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var content: some View {
        switch search.results {
        case .idle:
            if let source = search.source {
                sourceNote(source.text)
                    .padding(Spacing.cardGap)
                Spacer(minLength: 0)
            } else {
                EmptyState(icon: "magnifyingglass", title: AddSkillCopy.idleTitle, body: AddSkillCopy.idleBody)
            }
        case .searching:
            Spinner(label: AddSkillCopy.searching)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            FailureBanner(message, onRetry: search.retry)
                .padding(Spacing.cardGap)
            Spacer(minLength: 0)
        case .loaded(let document) where document.results.isEmpty:
            EmptyState(
                icon: nil, title: AddSkillCopy.noResults(search.term ?? search.query),
                body: AddSkillCopy.noResultsBody(
                    sources: search.repositories.filter(\.allowed).map(\.name),
                    skillsShOn: Self.skillsShOn(document.skillsSh)))
        case .loaded:
            if let filter = search.sourceFilter, search.isFilterEmpty {
                filterEmptyState(filter)
            } else {
                list
            }
        }
    }

    /// The consent answer as the empty state words it: nil while undecided or unknown.
    static func skillsShOn(_ state: SearchDocument.SkillsSh) -> Bool? {
        switch state {
        case .enabled: true
        case .disabled: false
        case .undecided, .unknown: nil
        }
    }

    private var list: some View {
        List(selection: $search.selection) {
            ForEach(search.filteredResults, id: \.name) { result in
                ResultRow(
                    result: result, installedAs: search.installedSkills(of: result),
                    isBlocked: search.isBlocked(result), isSelected: result.name == search.selection,
                    isPersonal: search.store.scope.isPersonal
                )
                .tag(Optional(result.name))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(AddSkillCopy.fieldLabel)
    }

    /// The source filter hides every result: what the other sources found, and Show All (as the Skills list's
    /// "Nothing in <filter>").
    private func filterEmptyState(_ filter: String) -> some View {
        EmptyState(
            icon: nil, title: AddSkillCopy.noResultsFrom(SourceFilterBar.label(of: filter, in: search.sourceChips)),
            body: AddSkillCopy.resultsElsewhere(search.totalResultCount),
            actions: [.secondary(EmptyCopy.showAll) { search.sourceFilter = nil }])
    }

    /// AddSkill-States: the accent-soft note that a typed source opens the preview without a search.
    private func sourceNote(_ source: String) -> some View {
        HStack(spacing: Spacing.rowGap) {
            Image(systemName: "shippingbox")
                .foregroundStyle(Color.accent)
                .accessibilityHidden(true)
            FailureBanner.styled(AddSkillCopy.sourceSkipsSearch(source), fragment: source, font: Font.Token.callout)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Spacing.cardGap)
        .padding(.horizontal, Spacing.m)
        .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
    }
}

/// AddSkill board: "Also search skills.sh?", asked once; either answer is remembered in config.toml.
private struct ConsentCard: View {
    let onDecline: () -> Void
    let onAccept: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            Text(AddSkillCopy.consentTitle)
                .font(Font.Token.bodyEmphasis)
            Text(AddSkillCopy.consentBody)
                .font(Font.Token.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.inline) {
                Spacer(minLength: 0)
                Button(AddSkillCopy.consentDecline, action: onDecline)
                    .buttonStyle(.bordered)
                Button(AddSkillCopy.consentAccept, action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accent)
            }
            .controlSize(.small)
        }
        .foregroundStyle(Color.textPrimary)
        .padding(.vertical, Spacing.cardGap)
        .padding(.horizontal, Spacing.m)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(Color.separator, lineWidth: Size.hairline))
    }
}

/// The sheet's body: the results column at `ResultsColumn.width(in:)` of the width offered, the hairline, and the
/// preview in the rest, all at the full height. One layout at every size, so a resize moves the columns without
/// rebuilding them, and nothing it measures leaves the sheet. It takes the size proposed as is (the board size
/// when none is), so the sheet's outer min/max frame in `AddSkillSheet` is what bounds it.
struct AddSkillColumns: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: Size.addSkillSheet)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = ResultsColumn.width(in: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let width =
                switch index {
                case 0: column
                case 1: Size.hairline
                default: max(0, bounds.maxX - x)
                }
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}
