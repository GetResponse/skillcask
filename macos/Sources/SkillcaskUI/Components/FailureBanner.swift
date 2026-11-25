import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The failure banner of a run (S11; Running, Components and AddSkill-States boards): a status-tinted callout
/// with a 16 pt symbol, the bold title, the reason and the action as 12 pt sentences, then the buttons the
/// failure allows: Open Settings (sign-in), Retry (a network failure, a time limit, or a read to try again),
/// Details, and Dismiss at the trailing end. The integrity variant adds the red border and "Not retried
/// automatically" and never offers Retry. The caller places it at the top of the list column or inside a sheet.
///
/// Two layouts, decided by `layout(for:hasRetry:hasDetails:)`: the Running board stacks title, body and an
/// action row (sign-in, integrity, anything with Details); AddSkill-States draws a failure with Retry on one
/// line, title then body, with Retry as the trailing control in the slot Dismiss takes elsewhere.
public struct FailureBanner: View {
    /// How the banner lays itself out.
    public enum Layout: Hashable, Sendable {
        /// Title, body, then the action row (Running board).
        case stacked
        /// Title and body inline, Retry (and Dismiss) trailing on the same line (AddSkill-States board).
        case inline
    }

    nonisolated static let errorSymbol = "xmark.circle"
    nonisolated static let integritySymbol = "xmark.shield"
    nonisolated static let warningSymbol = "exclamationmark.triangle"
    /// The network failure's symbol (AddSkill-States, ReviewUpdate-States).
    nonisolated static let networkSymbol = "wifi.slash"
    /// A read the app stopped at its time limit. Invented (no board draws it).
    nonisolated static let timeoutSymbol = "clock.badge.exclamationmark"
    nonisolated static let infoSymbol = "info.circle"

    private let message: UserMessage
    private let onDetails: (() -> Void)?
    private let onDismiss: (() -> Void)?
    private let onRetry: (() -> Void)?
    private let onSignIn: (() -> Void)?

    /// - Parameters:
    ///   - message: From `ErrorCopy`.
    ///   - onDetails: Opens Activity at the run; nil hides the link.
    ///   - onDismiss: Removes the banner; nil hides the button.
    ///   - onRetry: Runs again; shown only for `remedy == .retry`.
    ///   - onSignIn: Opens Settings at the token field; shown only for `remedy == .signIn`.
    public init(
        _ message: UserMessage, onDetails: (() -> Void)? = nil, onDismiss: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil, onSignIn: (() -> Void)? = nil
    ) {
        self.message = message
        self.onDetails = onDetails
        self.onDismiss = onDismiss
        self.onRetry = onRetry
        self.onSignIn = onSignIn
    }

    /// The symbol a message draws by its cause: the shield for integrity, the clock for a time limit, the crossed
    /// wifi for a network failure; otherwise by severity: the cross for an error, the triangle for a warning, the
    /// circle for anything quieter.
    nonisolated static func symbol(for message: UserMessage) -> String {
        if message.isIntegrity { return integritySymbol }
        if message.isTimeout { return timeoutSymbol }
        if message.isNetwork { return networkSymbol }
        switch message.severity {
        case .error: return errorSymbol
        case .warning: return warningSymbol
        case .neutral, .ok, .update: return infoSymbol
        }
    }

    /// Retry is offered where the message asks for it (`remedy == .retry`), never for an integrity failure (the
    /// board's note).
    nonisolated static func showsRetry(_ message: UserMessage) -> Bool {
        message.remedy == .retry && !message.isIntegrity
    }

    nonisolated static func showsSignIn(_ message: UserMessage) -> Bool {
        message.remedy == .signIn
    }

    /// Inline when Retry is the only control besides Dismiss: a retryable message with a retry handler and no
    /// Details link. Everything else stacks.
    nonisolated static func layout(for message: UserMessage, hasRetry: Bool, hasDetails: Bool) -> Layout {
        showsRetry(message) && hasRetry && !hasDetails ? .inline : .stacked
    }

    /// The reason and the action as the board's second line, one sentence after the other.
    nonisolated static func bodyText(_ message: UserMessage) -> String {
        [message.reason, message.action].compactMap { $0 }.joined(separator: " ")
    }

    /// `text` in `font`, with the first `fragment` in `Font.Token.monoSmall` (the policy refusal's source list).
    nonisolated static func styled(_ text: String, fragment: String?, font: Font) -> Text {
        guard let fragment, !fragment.isEmpty, let range = text.range(of: fragment) else {
            return Text(text).font(font)
        }
        return Text(text[..<range.lowerBound]).font(font)
            + Text(text[range]).font(Font.Token.monoSmall)
            + Text(text[range.upperBound...]).font(font)
    }

    public var body: some View {
        HStack(alignment: layout == .inline ? .center : .top, spacing: Spacing.rowGap) {
            Image(systemName: Self.symbol(for: message))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: Size.iconSidebar, height: Size.iconSidebar)
                .foregroundStyle(statusColor)
                .padding(.top, layout == .inline ? 0 : Size.hairline)
                .accessibilityHidden(true)
            switch layout {
            case .inline:
                inlineText
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailingControls
            case .stacked:
                stackedText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Spacing.cardGap)
        .padding(.horizontal, Spacing.m)
        .background(
            Color.statusTint(message.severity), in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
        )
        .overlay {
            if message.isIntegrity {
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(Color.statusErrorDot, lineWidth: Size.hairline)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.title)
    }

    // MARK: - Subviews

    private var layout: Layout {
        Self.layout(for: message, hasRetry: onRetry != nil, hasDetails: onDetails != nil)
    }

    private var statusColor: Color { Color.statusText(message.severity) }

    private var bodyLabel: Text {
        Self.styled(Self.bodyText(message), fragment: message.monoFragment, font: Font.Token.callout)
    }

    /// AddSkill-States: `<strong>Couldn’t reach packagist.</strong> Check your connection and try again…`.
    private var inlineText: some View {
        (Text(message.title).font(Font.Token.bodyEmphasis) + Text(" ") + bodyLabel)
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var stackedText: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(message.title)
                .font(Font.Token.bodyEmphasis)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !Self.bodyText(message).isEmpty {
                bodyLabel
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if hasActions {
                actionRow
            }
        }
    }

    private var hasActions: Bool {
        onDetails != nil || onDismiss != nil || (onRetry != nil && Self.showsRetry(message))
            || (onSignIn != nil && Self.showsSignIn(message)) || message.isIntegrity
    }

    private var actionRow: some View {
        HStack(spacing: Spacing.s) {
            if let onSignIn, Self.showsSignIn(message) {
                link(OutcomeCopy.openSettings, action: onSignIn)
            }
            if let onRetry, Self.showsRetry(message) {
                button(OutcomeCopy.retry, action: onRetry)
            }
            if let onDetails {
                link(OutcomeCopy.details, action: onDetails)
            }
            if message.isIntegrity {
                Text(OutcomeCopy.notRetried)
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: Spacing.s)
            if let onDismiss {
                button(OutcomeCopy.dismiss, action: onDismiss)
            }
        }
        .padding(.top, Spacing.xs)
    }

    /// The inline layout's trailing slot: Retry, then Dismiss when the caller offers it.
    private var trailingControls: some View {
        HStack(spacing: Spacing.s) {
            if let onRetry {
                button(OutcomeCopy.retry, action: onRetry)
            }
            if let onDismiss {
                button(OutcomeCopy.dismiss, action: onDismiss)
            }
        }
    }

    /// The board's `.btn.sm` (22 pt, `Size.buttonSmall`) is the system small bordered button, which AppKit draws
    /// 20 pt tall; a `.frame(height:)` would only pad the hit area around it, so the system size stands.
    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    /// The board's link: 12 pt semibold in the status text colour, a plain button.
    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Font.Token.calloutSemibold)
                .foregroundStyle(statusColor)
        }
        .buttonStyle(.plain)
    }
}

#Preview("FailureBanner, light") {
    VStack(spacing: Spacing.s) {
        FailureBanner(
            ErrorCopy.message(for: DesignFixtures.signInBanner.error, title: DesignFixtures.signInBanner.title),
            onDetails: {}, onDismiss: {}, onSignIn: {})
        FailureBanner(
            ErrorCopy.message(for: DesignFixtures.integrityBanner.error, title: DesignFixtures.integrityBanner.title),
            onDetails: {}, onDismiss: {})
        FailureBanner(ErrorCopy.message(for: DesignFixtures.unreachableFailure.error), onRetry: {})
    }
    .padding(Spacing.s)
    .frame(width: Size.listWidth)
    .background(Color.surfaceWindow)
}

#Preview("FailureBanner, dark") {
    VStack(spacing: Spacing.s) {
        FailureBanner(
            ErrorCopy.message(for: DesignFixtures.signInBanner.error, title: DesignFixtures.signInBanner.title),
            onDetails: {}, onDismiss: {}, onSignIn: {})
        FailureBanner(
            ErrorCopy.message(for: DesignFixtures.integrityBanner.error, title: DesignFixtures.integrityBanner.title),
            onDetails: {}, onDismiss: {})
        FailureBanner(ErrorCopy.message(for: DesignFixtures.unreachableFailure.error), onRetry: {})
    }
    .padding(Spacing.s)
    .frame(width: Size.listWidth)
    .background(Color.surfaceWindow)
    .preferredColorScheme(.dark)
}
