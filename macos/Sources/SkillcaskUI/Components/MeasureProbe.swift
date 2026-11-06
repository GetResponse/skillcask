import SwiftUI

extension View {
    /// Debug builds only: the view inside `MeasureProbe`, which records the widths SwiftUI measures it at
    /// (`CardContainer`'s content, for `OverviewLayoutCostTests`). A release build returns the view itself, so the
    /// probe costs nothing there. One view: a `Group` or other multi-view content would become the probe's subviews.
    func measureProbe() -> some View {
        #if DEBUG
            MeasureProbe { self }
        #else
            self
        #endif
    }
}

#if DEBUG
    /// A pass-through layout of one view that records the width of every measurement SwiftUI asks of it. A
    /// measurement SwiftUI answers from its own cache never reaches `sizeThatFits`, so the record is the layout work
    /// the view was given.
    struct MeasureProbe: Layout {
        /// The proposed widths since the last reset, across every probe; nil is an unspecified width.
        nonisolated(unsafe) static var widths: [CGFloat?] = []

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            Self.widths.append(proposal.width)
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
        }
    }
#endif
