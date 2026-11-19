import AppKit
import QuickLook
import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The detail's Contents tab (S4; Contents, Contents-States): the file line with Open in editor, Quick Look and
/// Copy path, then the invisible-character strip when the audit found any, the front matter as a key/value card
/// and the body rendered read-only (`MarkdownBody`). A file over the 256 KiB cap is not rendered ("Too large to
/// preview", Open in editor); a file that cannot be read says so with the folder's path, Open folder and Check,
/// and its Details link discloses the read error the detail carries.
///
/// Size and date come from the file's attributes, read off the main actor when the tab appears (Q6). Previews pass
/// `file` so nothing is read from disk.
struct ContentsTab: View {
    let entry: SkillEntry
    let detail: SkillDetail?
    var isLoading = false
    /// The scope's directory; the file is `<root>/<entry.path>/SKILL.md`.
    let root: URL
    /// Known facts about the file; nil reads them from disk.
    var file: ContentsFile?
    /// The strip's See Security.
    var onSeeSecurity: () -> Void = {}
    /// Check on the unreadable file: reads the detail again.
    var onCheck: () -> Void = {}
    /// A file line to scroll to and highlight (Security's "Show in file", S5); nil when nothing asked.
    var targetLine: Int?
    /// Called once the target was shown, so the owner clears it.
    var onTargetShown: () -> Void = {}

    @State private var loadedFile: ContentsFile?
    @State private var quickLookURL: URL?
    /// The block "Show in file" highlights for `highlightDuration`.
    @State private var highlighted: Int?
    /// The row whose read error Details disclosed; another row starts closed.
    @State private var detailsShown: SkillEntry.ID?
    /// The body's blocks and flags, parsed once per text rather than on every body pass.
    @State private var memo = ContentsMemo()

    init(
        entry: SkillEntry, detail: SkillDetail?, isLoading: Bool = false, root: URL, file: ContentsFile? = nil,
        onSeeSecurity: @escaping () -> Void = {}, onCheck: @escaping () -> Void = {}, targetLine: Int? = nil,
        onTargetShown: @escaping () -> Void = {}, showsDetails: Bool = false
    ) {
        self.entry = entry
        self.detail = detail
        self.isLoading = isLoading
        self.root = root
        self.file = file
        self.onSeeSecurity = onSeeSecurity
        self.onCheck = onCheck
        self.targetLine = targetLine
        self.onTargetShown = onTargetShown
        _detailsShown = State(initialValue: showsDetails ? entry.id : nil)
    }

    // MARK: - Board values

    /// Contents board `.fm { grid-template-columns: 110px … }`.
    static let frontMatterLabelWidth: CGFloat = 110
    /// `.fm > * { padding: 4px 0 }`.
    static let frontMatterRowPadding: CGFloat = Spacing.xs
    /// The front-matter card's `padding: 6px 12px`.
    static let frontMatterPaddingV: CGFloat = Spacing.inline

    /// How long the "Show in file" highlight stays; a moment, as a find-in-page flash.
    static let highlightDuration: Duration = .seconds(1.5)

    /// `<root>/<path>/SKILL.md`, or nil for a row without a folder.
    static func fileURL(root: URL, path: String?) -> URL? {
        path.map { root.appending(path: $0).appending(path: ContentsFile.skillFileName) }
    }

    var body: some View {
        VStack(spacing: 0) {
            fileBar
            Rectangle()
                .fill(Color.separator)
                .frame(height: Size.hairline)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.surfaceWindow)
        .task(id: TaskKey(url: url, detail: detail, fingerprint: detail?.text.map(memo.textHash))) {
            guard file == nil, let url else { return }
            loadedFile = await ContentsFile.load(at: url)
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: - Derived

    private var url: URL? {
        file?.url ?? Self.fileURL(root: root, path: entry.path)
    }

    private var facts: ContentsFile {
        file ?? loadedFile.flatMap { $0.url == url ? $0 : nil } ?? ContentsFile(url: url)
    }

    /// Details is open for this row.
    private var showsDetails: Bool {
        detailsShown == entry.id
    }

    private var state: ContentsState {
        ContentsState.resolve(entry: entry, detail: detail, isLoading: isLoading)
    }

    // MARK: - Subviews

    /// `SKILL.md · 1.8 KB · changed 3 Oct 2026` and the three small buttons (board `padding: 8px 24px`).
    private var fileBar: some View {
        HStack(spacing: Spacing.s) {
            Text(fileLine)
                .font(Font.Token.mono)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.s)
            HStack(spacing: Spacing.inline) {
                Button(ContentsCopy.openInEditor, action: openInEditor)
                    .disabled(!state.canOpenFile || url == nil)
                Button(ContentsCopy.quickLook) { quickLookURL = url }
                    .disabled(!state.canOpenFile || url == nil)
                Button(ContentsCopy.copyPath, action: copyPath)
                    .disabled(url == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Size.columnPadding)
    }

    private var fileLine: String {
        // Unreadable: the name only (Contents-States), even if a stale size is known.
        state == .unreadable
            ? facts.name : ContentsCopy.fileLine(name: facts.name, bytes: facts.bytes, modified: facts.modified)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading:
            Color.clear
        case .normal(let text, let warnsInvisible):
            let parsed = memo.parsed(entry: entry, text: text)
            ScrollViewReader { proxy in
                ScrollView {
                    document(text, parsed: parsed, warnsInvisible: warnsInvisible)
                }
                .task(id: targetLine) { await reveal(targetLine, text: text, spans: parsed.spans, proxy: proxy) }
            }
        case .tooLarge:
            EmptyState(
                icon: "doc.text", title: EmptyCopy.tooLargeTitle,
                body: EmptyCopy.tooLargeBody(fileName: facts.name, bytes: facts.bytes ?? SkillText.maxBytes + 1),
                actions: [.primary(EmptyCopy.openInEditor, perform: openInEditor)],
                textWidth: EmptyState.tooLargeTextWidth)
        case .unreadable:
            // The board's page with an X: no SF Symbol on macOS 14 draws one, so `doc` carries an `xmark` badge.
            EmptyState(
                icon: "doc", iconBadge: "xmark", tone: .error, title: EmptyCopy.unreadableTitle(fileName: facts.name),
                body: EmptyCopy.unreadableBody, detail: facts.displayPath,
                actions: [
                    .secondary(EmptyCopy.openContainingFolder, perform: openFolder),
                    .primary(EmptyCopy.check, perform: onCheck),
                ],
                link: detail?.textError
                    .map { _ in
                        .secondary(showsDetails ? ContentsCopy.hideDetails : ContentsCopy.details) {
                            detailsShown = showsDetails ? nil : entry.id
                        }
                    },
                disclosed: showsDetails ? detail?.textError : nil,
                textWidth: EmptyState.unreadableTextWidth)
        }
    }

    /// The strip, the front matter and the body with its outlined and highlighted blocks.
    private func document(_ text: SkillText, parsed: ContentsMemo.Parsed, warnsInvisible: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if warnsInvisible {
                MessageStrip(
                    .warning, text: StripCopy.invisibleCharacters, monoFragment: StripCopy.escapedOverride,
                    symbol: MessageStrip.invisibleSymbol, density: .strip,
                    trailing: .link(StripCopy.seeSecurity, action: onSeeSecurity))
            }
            if !text.frontMatter.isEmpty {
                FrontMatterCard(rows: text.frontMatter)
            }
            MarkdownBody(spans: parsed.spans, flags: parsed.flags, highlighted: highlighted)
        }
        .padding(.horizontal, Size.columnPadding)
        .padding(.top, Spacing.m)
        .padding(.bottom, Size.columnPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// Scrolls to the block of `line`, highlights it for a moment, then tells the owner it was shown. A newer
    /// target cancels this run before it clears anything; a line outside the body is consumed without scrolling.
    private func reveal(
        _ line: Int?, text: SkillText, spans: [MarkdownBlocks.Span], proxy: ScrollViewProxy
    ) async {
        guard let line else { return }
        guard let index = ContentsState.blockIndex(forFileLine: line, text: text, spans: spans) else {
            onTargetShown()
            return
        }
        withAnimation { proxy.scrollTo(index, anchor: .center) }
        highlighted = index
        try? await Task.sleep(for: Self.highlightDuration)
        guard !Task.isCancelled else { return }
        withAnimation { highlighted = nil }
        onTargetShown()
    }

    /// The user's plain-text editor (S4 note), through `SafeOpen`: a SKILL.md that resolves outside the folder or
    /// to anything but a plain-text file is not opened, Finder shows the folder instead.
    private func openInEditor() {
        guard let url else { return }
        Workspace.openAsText(url, inside: url.deletingLastPathComponent())
    }

    private func copyPath() {
        guard let url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Finder selects the folder that should hold SKILL.md (never opens it: `SafeOpen`); when it is gone too, Finder
    /// shows where it would be.
    private func openFolder() {
        guard let folder = url?.deletingLastPathComponent() else { return }
        Workspace.revealFolder(folder)
    }

    /// Re-reads the attributes when the row or its loaded text changes (after Check, or a SKILL.md edited outside
    /// the app). Cheap to hash on every body pass: the url and the text's fingerprint (`ContentsMemo.textHash`,
    /// computed once per loaded text), never the whole detail with its info document and body. An edit of the same
    /// length, or one inside the front matter, changes the fingerprint.
    struct TaskKey: Hashable {
        let url: URL?
        let hasDetail: Bool
        let fingerprint: Int?
        let textError: String?

        init(url: URL?, detail: SkillDetail?, fingerprint: Int?) {
            self.url = url
            hasDetail = detail != nil
            self.fingerprint = fingerprint
            textError = detail?.textError
        }
    }
}

/// The last SKILL.md the Contents tab parsed: its block spans and the audit flags on them, kept for as long as the
/// text and the row's findings stay the same, so a body pass (hover, highlight, a store tick) re-uses them. A plain
/// class in `@State`: reading or filling it never invalidates the view.
@MainActor final class ContentsMemo {
    struct Parsed: Equatable {
        let spans: [MarkdownBlocks.Span]
        let flags: [Int: DiffFlag.Kind]
    }

    private struct Key: Equatable {
        let text: SkillText
        let path: String?
        let findings: [AuditDocument.Finding]
    }

    private var key: Key?
    private var value: Parsed?
    /// How many times a text was parsed (tests).
    private(set) var parses = 0
    private var fingerprinted: (text: SkillText, value: Int)?
    /// How many times a text was hashed for `fingerprint` (tests).
    private(set) var fingerprints = 0

    /// The hash of `text` (body, front matter, start line, truncation), kept for the last text (`TaskKey.fingerprint`): a body pass with the
    /// same loaded text costs one comparison of the same string storage, not a hash of the whole file.
    func textHash(_ text: SkillText) -> Int {
        if let fingerprinted, fingerprinted.text == text {
            return fingerprinted.value
        }
        let value = text.hashValue
        fingerprinted = (text, value)
        fingerprints += 1
        return value
    }

    func parsed(entry: SkillEntry, text: SkillText) -> Parsed {
        let key = Key(text: text, path: entry.path, findings: entry.findings)
        if let value, key == self.key {
            return value
        }
        let spans = MarkdownBlocks.spans(text.body)
        let parsed = Parsed(spans: spans, flags: ContentsState.flags(for: entry, text: text, spans: spans))
        self.key = key
        value = parsed
        parses += 1
        return parsed
    }
}

/// The front matter as the board's card: a 110 pt label column, hairlines between rows, `type.callout`; the values
/// of `ContentsCopy.monoKeys` in `type.mono.small`.
private struct FrontMatterCard: View {
    let rows: [(key: String, value: String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Color.separator)
                        .frame(height: Size.hairline)
                }
                GridRow {
                    Text(row.key)
                        .font(Font.Token.callout)
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: ContentsTab.frontMatterLabelWidth, alignment: .leading)
                        .padding(.vertical, ContentsTab.frontMatterRowPadding)
                    Text(DiffCopy.shown(row.value))
                        .font(ContentsCopy.monoKeys.contains(row.key) ? Font.Token.monoSmall : Font.Token.callout)
                        .foregroundStyle(Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, ContentsTab.frontMatterRowPadding)
                }
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, ContentsTab.frontMatterPaddingV)
        .padding(.horizontal, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.l))
        .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Color.separator, lineWidth: Size.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ContentsCopy.frontMatter)
    }
}
