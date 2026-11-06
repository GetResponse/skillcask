import SkillcaskCore
import SkillcaskUpdates
import SwiftUI

/// What the update sheet shows for an install method (U2/U3 as D51 changes them): the body, the pill and the
/// footer's buttons. Pure, so tests pick the body without drawing it.
struct AppUpdateSheetContent: Equatable {
    enum Body: Equatable {
        /// `Run in Terminal` and the one command row.
        case homebrew(command: String)
        /// `How to update`, naming the release's zip; nil for a version that is not strict (`UpdateLinks.zipName`).
        case direct(zip: String?)
        /// The temporary-copy callout and `Do this first`; the path row only when the original is known (its
        /// `Show in Finder` is the primary button, not a second one in the row).
        case translocated(original: URL?)
        /// The organisation updates the app (`[updates] managed`, D61): its words, no steps.
        case managed(String)
    }

    let body: Body
    let pill: String
    /// `Skip This Version` at the footer's leading end; a temporary copy has none (it is not that version's fault).
    let offersSkip: Bool
    /// The footer's buttons before the primary, left to right.
    let secondary: [AppUpdateStore.SheetAction]
    /// The default button.
    let primary: AppUpdateStore.SheetAction

    init(method: InstallMethod, version: Version, managed: String? = nil) {
        pill = AppUpdateCopy.pill(method)
        if let managed {
            body = .managed(managed)
            offersSkip = true
            secondary = [.remindTomorrow]
            primary = .openReleasePage
            return
        }
        switch method {
        case .homebrew:
            body = .homebrew(command: UpdateLinks.homebrewCommand)
            offersSkip = true
            secondary = [.remindTomorrow, .copyAndOpenTerminal]
            primary = .copyCommand
        case .direct:
            body = .direct(zip: UpdateLinks.zipName(for: version))
            offersSkip = true
            secondary = [.remindTomorrow]
            primary = .openReleasePage
        case .translocated(let original):
            body = .translocated(original: original)
            offersSkip = false
            secondary = [.remindTomorrow]
            primary = original.map { .showInFinder($0) } ?? .openReleasePage
        }
    }
}

/// The update sheet (U2/U3), presented by `MainWindow` for `AppUpdateStore.sheet` on a host of its own, never over
/// the onboarding sheet or a scope sheet: the header (icon, versions, how this copy was installed, the release page
/// on GitHub), the steps for the install method and the footer. Every footer button acts through
/// `AppUpdateStore.perform(_:on:)` and closes the sheet; Esc closes it with no state change.
///
/// Deviations from the U2/U3 boards: DESIGN.md G14.
struct AppUpdateSheet: View {
    let version: Version
    let installed: Version

    @Environment(AppUpdateStore.self) private var updates

    /// The width: the Homebrew footer's four buttons at full length; no notes box, so U2's 740 would be empty
    /// space.
    nonisolated static let width: CGFloat = 680
    /// The app tile (U2: 48 pt, radius 12).
    static let tileSize: CGFloat = 48
    static let tileRadius: CGFloat = 12
    static let glyphSize: CGFloat = 26
    /// The command row's corners (`CLIOnboardingSheet.commandRadius`).
    static let commandRadius = CLIOnboardingSheet.commandRadius

    private var content: AppUpdateSheetContent {
        AppUpdateSheetContent(method: updates.installMethod, version: version, managed: updates.state.managed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            bodySection
            footer
        }
        .frame(width: Self.width)
        .background(Color.surfaceWindow)
        .background {
            // Esc: closes, changes nothing.
            Button(AppUpdateCopy.close) { updates.dismissSheet() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
                .fill(Color.accent)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .overlay {
                    Image(systemName: "shippingbox")
                        .resizable()
                        .scaledToFit()
                        .frame(width: Self.glyphSize, height: Self.glyphSize)
                        .foregroundStyle(CLIOnboardingSheet.glyphColor)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(AppUpdateCopy.availableTitle(version))
                    .font(Font.Token.sheetTitle)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(AppUpdateCopy.availableSubtitle(installed: installed) + ".")
                    .font(Font.Token.body)
                    .foregroundStyle(Color.textSecondary)
                Button(AppUpdateCopy.releaseNotes) { updates.openReleaseNotes(for: version) }
                    .controlSize(.small)
                    .padding(.top, Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Pill(content.pill)
        }
        .padding(Spacing.xxl)
        .overlay(alignment: .bottom) { hairline }
    }

    // MARK: - Body

    @ViewBuilder private var bodySection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            switch content.body {
            case .homebrew(let command):
                sectionTitle(AppUpdateCopy.runInTerminal)
                commandRow(command)
                Text(AppUpdateCopy.homebrewCaption)
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .direct(let zip):
                sectionTitle(AppUpdateCopy.howToUpdateTitle)
                howToUpdate(zip: zip)
            case .translocated(let original):
                MessageStrip(
                    .warning, title: AppUpdateCopy.translocatedLead, text: AppUpdateCopy.translocatedBody,
                    symbol: "exclamationmark.triangle", density: .sheet)
                sectionTitle(AppUpdateCopy.doThisFirst)
                Text(AppUpdateCopy.doThisFirstBody)
                    .font(Font.Token.body)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let original {
                    pathRow(original)
                }
            case .managed(let message):
                sectionTitle(AppUpdateCopy.managedTitle)
                Text(message)
                    .font(Font.Token.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Font.Token.bodyEmphasis)
            .foregroundStyle(Color.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    /// `Download <zip> from the release page, …` with the zip name in mono.
    private func howToUpdate(zip: String?) -> some View {
        let sentence = AppUpdateCopy.howToUpdate(zip: zip)
        let text: Text =
            if let zip, let range = sentence.range(of: zip) {
                Text(sentence[..<range.lowerBound]) + Text(zip).font(Font.Token.mono)
                    + Text(sentence[range.upperBound...])
            } else {
                Text(sentence)
            }
        return
            text
            .font(Font.Token.body)
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The selectable command in mono and its Copy button (labelled with the command for VoiceOver).
    private func commandRow(_ command: String) -> some View {
        boxedRow {
            Text(command)
                .font(Font.Token.mono)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(AppUpdateCopy.copy) { updates.perform(.copyCommand, on: version) }
                .controlSize(.small)
                .accessibilityLabel(AppUpdateCopy.copyLabel(command))
        }
    }

    /// Where the user's copy lies; the footer's primary shows it in Finder.
    private func pathRow(_ original: URL) -> some View {
        boxedRow {
            Text((original.path as NSString).abbreviatingWithTildeInPath)
                .font(Font.Token.mono)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func boxedRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Spacing.s) {
            content()
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, CLIOnboardingSheet.commandPaddingH)
        .background(Color.surfaceGrouped, in: RoundedRectangle(cornerRadius: Self.commandRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.commandRadius)
                .strokeBorder(Color.separator, lineWidth: Size.hairline))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Spacing.s) {
            if content.offersSkip {
                actionButton(.skip)
            }
            Spacer(minLength: Spacing.s)
            ForEach(content.secondary, id: \.self) { action in
                actionButton(action)
            }
            Button(AppUpdateCopy.title(for: content.primary)) { updates.perform(content.primary, on: version) }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        }
        .font(Font.Token.bodyMedium)
        .padding(.vertical, Spacing.m)
        .padding(.horizontal, Spacing.xxl)
        .background(Color.surfaceGrouped)
        .overlay(alignment: .top) { hairline }
    }

    private func actionButton(_ action: AppUpdateStore.SheetAction) -> some View {
        Button(AppUpdateCopy.title(for: action)) { updates.perform(action, on: version) }
            .fixedSize()
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.separator)
            .frame(height: Size.hairline)
    }
}
