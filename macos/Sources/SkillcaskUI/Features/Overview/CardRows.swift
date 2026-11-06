import SwiftUI

/// The Overview's cards in `columns` equal columns, `spacing` apart both ways, in source order row by row. Each
/// card is measured at its column's width with no height limit, the row takes the tallest card's height, and every
/// card of the row is offered that height: `CardContainer` takes it, so the cards of a row stretch to the taller one
/// as the boards' CSS grid does, and a wrapping cell never draws taller than it was measured.
///
/// One layout for one and two columns: a column change moves the cards and keeps them (a Health disclosure stays
/// open), where two `if` branches built six new cards. Each card is measured only at its column's width; a flexible
/// `HStack` row of cards measured each at zero, unbounded and its share of the width, and every line of every card
/// was broken again for each of them (`OverviewLayoutCostTests`).
struct CardRows: Layout {
    let columns: Int
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let column = columnWidth(proposal.width, subviews)
        let heights = rowHeights(subviews, column: column)
        return CGSize(
            width: column * CGFloat(columnCount) + spacing * CGFloat(columnCount - 1),
            height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, column: column).enumerated() {
            for (index, subview) in cards(of: row, subviews).enumerated() {
                subview.place(
                    at: CGPoint(x: bounds.minX + CGFloat(index) * (column + spacing), y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: column, height: height))
            }
            y += height + spacing
        }
    }

    // MARK: - Derived

    private var columnCount: Int { max(columns, 1) }

    /// The width of one column within `width`; without a finite width, the widest card's ideal width.
    private func columnWidth(_ width: CGFloat?, _ subviews: Subviews) -> CGFloat {
        guard let width, width.isFinite else {
            return subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        }
        return max((width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount), 0)
    }

    /// Each row's height: its tallest card at the column's width.
    private func rowHeights(_ subviews: Subviews, column: CGFloat) -> [CGFloat] {
        let rows = (subviews.count + columnCount - 1) / columnCount
        let proposal = ProposedViewSize(width: column, height: nil)
        return (0..<rows).map { row in cards(of: row, subviews).map { $0.sizeThatFits(proposal).height }.max() ?? 0 }
    }

    private func cards(of row: Int, _ subviews: Subviews) -> Subviews.SubSequence {
        let start = subviews.startIndex + row * columnCount
        return subviews[start..<min(start + columnCount, subviews.endIndex)]
    }
}
