import SkillcaskCore
import SwiftUI

/// The Overview header's warning when a read failed while a snapshot stays on screen: a refresh that read `status`
/// but not `audit` or `doctor` (`ScopeStore.partialFailure`), one that failed entirely (`refreshError`) or a failed
/// check (`checkError`). One compact strip and a Details link that shows the failure under it (the error's
/// sentences and the CLI's stderr), selectable, as a banner's Details would.
struct PartialRefreshStrip: View {
    let text: String
    let error: CLIError
    @State private var showsDetails: Bool

    /// - Parameter showsDetails: Starts with the details open (previews).
    init(_ failure: ScopeStore.PartialFailure, showsDetails: Bool = false) {
        self.init(StripCopy.partialRefresh(failure), error: failure.error, showsDetails: showsDetails)
    }

    init(_ text: String, error: CLIError, showsDetails: Bool = false) {
        self.text = text
        self.error = error
        _showsDetails = State(initialValue: showsDetails)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            MessageStrip(
                .warning, text: text, density: .compact,
                trailing: .link(showsDetails ? StripCopy.hideDetails : OutcomeCopy.details) {
                    showsDetails.toggle()
                })
            if showsDetails {
                Text(Self.details(of: error))
                    .font(Font.Token.monoSmall)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What Details shows: the message's sentences, then the transcript when there is one.
    static func details(of error: CLIError) -> String {
        let message = ErrorCopy.message(for: error)
        return [message.title, message.reason, message.action, message.details].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
