import SkillcaskCore
import SwiftUI

/// Settings › Search (Settings board, right window): the skills.sh switch, which reads and writes `[search]
/// skills-sh` in config.toml through `CLISettingsStore` (`-g config`), the sources searched for the open project, and the
/// ranking footnote.
struct SearchPane: View {
    @Environment(AppStore.self) private var app

    var body: some View {
        SettingsPane {
            SettingsGroup {
                SettingsRow(label: SettingsCopy.alsoSearchSkillsSh, alignment: .top) {
                    HStack(alignment: .top, spacing: Spacing.cardGap) {
                        Toggle(SettingsCopy.alsoSearchSkillsSh, isOn: skillsShBinding)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .tint(Color.accent)
                            .disabled(app.cliContext == nil || store.isWritingConfig)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            SettingsNote(note)
                            if let failure = store.skillsShFailure {
                                MessageStrip(
                                    .error, title: failure.title, text: failure.reason ?? failure.action ?? "",
                                    density: .compact)
                            }
                        }
                    }
                }
                SettingsSeparator()
                SettingsRow(label: SettingsCopy.sourcesSearchedLabel, alignment: .top) {
                    SettingsNote(SettingsCopy.sourcesSearched(projectSources, project: projectName))
                }
            }
            SettingsCaption(SettingsCopy.searchFooter)
        }
        .task(id: app.capabilities) {
            if let context = app.cliContext {
                await store.loadSkillsSh(in: context)
            }
        }
    }

    private var store: CLISettingsStore {
        app.cliSettings
    }

    /// On while config.toml says true, or while `true` is being written.
    private var isOn: Bool {
        store.pendingSkillsSh ?? (store.skillsSh == .on)
    }

    private var skillsShBinding: Binding<Bool> {
        Binding(
            get: { isOn },
            set: { on in
                guard let context = app.cliContext else { return }
                Task { await store.setSkillsSh(on, in: context) }
            })
    }

    /// The board's sentence, with `search.skills-sh = <value>` in mono once config.toml sets it.
    private var note: Text {
        let lead = SettingsCopy.skillsShNote + " "
        switch store.skillsSh {
        case .on, .off:
            return Text(lead + SettingsCopy.storedAs + " ")
                + Text(SettingsCopy.skillsShStored(isOn)).font(Font.Token.monoSmall)
                + Text(" " + SettingsCopy.storedIn(store.skillsShFrom))
        case .notSet:
            return Text(lead + SettingsCopy.skillsShNotSet)
        case .unknown:
            return Text(SettingsCopy.skillsShNote)
        }
    }

    // MARK: - Sources

    private var project: Scope? {
        guard let scope = app.selectedScope, !scope.isPersonal else { return nil }
        return scope
    }

    private var projectName: String? {
        project.map { AppStore.name(of: $0.root) }
    }

    private var projectSources: [String] {
        guard let project, let snapshot = app.visitedStore(for: project)?.snapshot else { return [] }
        return SettingsCopy.projectSources(snapshot.repositories)
    }
}
