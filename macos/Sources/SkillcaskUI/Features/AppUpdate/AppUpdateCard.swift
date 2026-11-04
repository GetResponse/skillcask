import SkillcaskCore
import SkillcaskUpdates
import SwiftUI

/// U1: the app-update card in the sidebar, above the Open Folder… line. One slot, one `UpdateCard` state: the
/// consent prompt (decision 3), an available version, or the wait after the Homebrew command was copied. Brand
/// accent and `accent.line` only, never `status.update` blue (blue means skill updates); it never touches a badge,
/// a count or a filter. Spacing from `AppUpdate-Main`: padding 10, gap 6, radius 8, 1 pt border, a 22 pt icon
/// tile with radius 6.
struct AppUpdateCard: View {
    let card: UpdateCard
    /// The app's version, for `You have Y`.
    let installed: Version
    var onConsent: (Bool) -> Void = { _ in }
    var onHide: () -> Void = {}
    var onSeeWhatsNew: (Version) -> Void = { _ in }

    /// The version last announced to VoiceOver, so a card announces once, not on every redraw.
    @State private var announced: UpdateCard?

    static let padding: CGFloat = 10
    static let gap: CGFloat = 6
    static let iconSize: CGFloat = 22
    static let iconRadius: CGFloat = 6
    static let iconGlyph: CGFloat = 13
    /// U1's small full-width buttons: 22 pt tall on the board, a small control with its label stretched.
    static let buttonHeight: CGFloat = 18

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Self.padding)
            .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.l))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.l)
                    .strokeBorder(border, lineWidth: Size.hairline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .onChange(of: card, initial: true) { announce() }
    }

    @ViewBuilder private var content: some View {
        switch card {
        case .none:
            EmptyView()
        case .consentPrompt:
            VStack(alignment: .leading, spacing: Self.gap) {
                heading(AppUpdateCopy.consentTitle, AppUpdateCopy.consentBody, icon: false)
                HStack(spacing: Spacing.inline) {
                    Button {
                        onConsent(false)
                    } label: {
                        Text(AppUpdateCopy.notNow).frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                    }
                    Button {
                        onConsent(true)
                    } label: {
                        Text(AppUpdateCopy.checkDaily).frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accent)
                }
                .controlSize(.small)
            }
        case .available(let version):
            VStack(alignment: .leading, spacing: Self.gap) {
                heading(
                    AppUpdateCopy.availableTitle(version), AppUpdateCopy.availableSubtitle(installed: installed),
                    hides: true)
                Button {
                    onSeeWhatsNew(version)
                } label: {
                    Text(AppUpdateCopy.seeWhatsNew)
                        .frame(maxWidth: .infinity, minHeight: Self.buttonHeight)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .controlSize(.small)
            }
        case .awaitingRelaunch:
            VStack(alignment: .leading, spacing: Self.gap) {
                heading(AppUpdateCopy.awaitingTitle, AppUpdateCopy.awaitingBody, icon: false)
            }
        }
    }

    /// The icon tile, the title (12 semibold) over the line (11 secondary), and the × when the card can hide.
    private func heading(_ title: String, _ subtitle: String, icon: Bool = true, hides: Bool = false) -> some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            if icon {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: Self.iconGlyph, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .background(Color.accent, in: RoundedRectangle(cornerRadius: Self.iconRadius))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(Font.Token.calloutSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text(subtitle)
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            // No vertical `fixedSize`: it makes the text's ideal height its minimum height, and outside the
            // sidebar's `List` that minimum, measured narrow, is forced onto the split view, which then shifts every
            // column up (observed on macOS 27, `SidebarCardLayoutTests`). The footer offers the card its ideal height,
            // so the lines wrap in full without it (`AppUpdateCardTextTests`).
            .frame(maxWidth: .infinity, alignment: .leading)
            if hides {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppUpdateCopy.hide)
                .help(AppUpdateCopy.hide)
            }
        }
    }

    private var border: Color {
        card == .awaitingRelaunch ? Color.separator : Color.accentLine
    }

    private var label: String {
        switch card {
        case .available: AppUpdateCopy.cardLabel
        case .consentPrompt: AppUpdateCopy.consentLabel
        case .awaitingRelaunch: AppUpdateCopy.awaitingLabel
        case .none: ""
        }
    }

    /// VoiceOver: the available card announces itself once when it appears.
    private func announce() {
        guard case .available(let version) = card, announced != card else { return }
        announced = card
        AccessibilityNotification.Announcement(AppUpdateCopy.availableTitle(version)).post()
    }
}

/// The card slot in the sidebar: what `AppUpdateStore.card` says, with the consent prompt held back until the CLI
/// is ready and no onboarding sheet covers the window (decision 3). Nothing at all while the feature is off.
struct AppUpdateCardSlot: View {
    @Environment(AppStore.self) private var app
    @Environment(AppUpdateStore.self) private var updates

    var body: some View {
        if let installed = updates.installed, let card = shown {
            AppUpdateCard(
                card: card, installed: installed, onConsent: { updates.answerConsent($0) },
                onHide: { updates.hideCard() }, onSeeWhatsNew: { updates.presentSheet(for: $0) }
            )
            .disabled(app.isPresenting)
            .padding(.horizontal, AppUpdateCard.padding)
            .padding(.bottom, Spacing.s)
        }
    }

    private var shown: UpdateCard? {
        let card = updates.card
        switch card {
        case .none: return nil
        case .consentPrompt: return app.isReady && !app.isOnboarding ? card : nil
        case .available, .awaitingRelaunch: return card
        }
    }
}
