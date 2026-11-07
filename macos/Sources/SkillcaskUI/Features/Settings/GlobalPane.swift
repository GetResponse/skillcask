import SkillcaskCore
import SwiftUI

/// Settings › Global (no board; after the maintainer's Settings window in upstream `eca0f53`): every key of
/// config.toml that `skillcask -g config --json` lists (D48), one Settings row each, with its value, the
/// layer it comes from, and a system control to change it through `CLISettingsStore`. A boolean is a switch that
/// writes at once; a list or a string is shown in mono and edited in place (Edit, then Save or Cancel); a key
/// config.toml sets has Unset, except an enforced one (the CLI refuses to unset it while `policy.enforce` lists
/// it). Read-only, with the reason under it: a key a `SKILLCASK_*` variable sets (the environment wins over the
/// file), a key the system config.toml enforces and its `policy.enforce` (D60), and `allow-sources` holding a URL
/// (shown redacted, so writing it back would drop its credentials). A key the user's config.toml enforces stays
/// editable: with `-g` config.toml is the user's own file, the CLI accepts the change, and enforcement only stops
/// projects from loosening it.
struct GlobalPane: View {
    @Environment(AppStore.self) private var app

    /// The key being edited and its text; previews seed it.
    @State private var editing: String?
    @State private var draft: String

    init(editing: String? = nil, draft: String = "") {
        _editing = State(initialValue: editing)
        _draft = State(initialValue: draft)
    }

    var body: some View {
        SettingsPane {
            content
        }
        .task(id: app.capabilities) {
            if let context = app.cliContext {
                await store.loadGlobalSettings(in: context)
            }
        }
    }

    private var store: CLISettingsStore {
        app.cliSettings
    }

    @ViewBuilder private var content: some View {
        if app.capabilities == nil {
            MessageStrip(.warning, text: SettingsCopy.globalNeedsCLI, density: .strip)
        } else if let failure = store.globalSettingsFailure {
            MessageStrip(.error, title: failure.title, text: failure.reason ?? failure.action ?? "", density: .compact)
        } else if let document = store.globalSettings {
            SettingsGroup {
                ForEach(Array(document.orderedKeys.enumerated()), id: \.element) { index, key in
                    if index > 0 {
                        SettingsSeparator()
                    }
                    row(key, document.settings[key] ?? ConfigValueDocument(value: .null, from: nil))
                }
            }
            SettingsCaption(SettingsCopy.globalFooter)
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Rows

    private func row(_ key: String, _ setting: ConfigValueDocument) -> some View {
        let kind = ConfigKey.kind(of: key, value: setting.value)
        let reason = Self.readOnlyReason(key, setting)
        return SettingsRow(label: SettingsCopy.settingLabel(key), alignment: .top) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if editing == key {
                    editor(key, kind, setting)
                } else {
                    control(key, kind, setting, readOnly: reason != nil)
                }
                (Text(key).font(Font.Token.monoSmall) + Text(" · " + SettingsCopy.layer(setting.layer)))
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
                if let reason {
                    SettingsCaption(reason)
                } else if setting.layer == .enforced {
                    SettingsCaption(SettingsCopy.enforcedNote + " " + SettingsCopy.unsetEnforcedFirst)
                }
                if let refusal = store.settingRefusal, refusal.key == key {
                    // Already masked by the store (`CLISettingsStore.masking`).
                    MessageStrip(
                        .error, title: refusal.message.title,
                        text: refusal.message.reason ?? refusal.message.action ?? "", density: .compact)
                }
            }
        }
    }

    @ViewBuilder private func control(
        _ key: String, _ kind: ConfigKey.Kind, _ setting: ConfigValueDocument, readOnly: Bool
    ) -> some View {
        HStack(spacing: Spacing.s) {
            if kind == .bool {
                Toggle(SettingsCopy.settingLabel(key), isOn: boolBinding(key, setting))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .tint(Color.accent)
                    .disabled(readOnly || !canChange)
            } else {
                Text(Self.shown(setting.value))
                    .font(Font.Token.mono)
                    .foregroundStyle(setting.value == .null ? Color.textSecondary : Color.textPrimary)
                    .textSelection(.enabled)
                    // One line, shortened in the middle (`packagist, https://…/composer/`); the whole value, as the
                    // CLI printed it (redacted), is the tooltip.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Self.shown(setting.value))
                if !readOnly {
                    Button(SettingsCopy.edit) {
                        draft = Self.draft(of: setting.value)
                        editing = key
                    }
                    .controlSize(.small)
                    .disabled(!canChange)
                }
            }
            if !readOnly, Self.canUnset(setting.layer) {
                Button(SettingsCopy.unset) { unset(key) }
                    .controlSize(.small)
                    .disabled(!canChange)
            }
            if store.changingSetting == key {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder private func editor(_ key: String, _ kind: ConfigKey.Kind, _ setting: ConfigValueDocument) -> some View
    {
        HStack(spacing: Spacing.s) {
            TextField(SettingsCopy.settingLabel(key), text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(Font.Token.mono)
                .labelsHidden()
                .onSubmit { save(key, kind, setting) }
            Button(SettingsCopy.save) { save(key, kind, setting) }
                .controlSize(.small)
                .disabled(!canChange || !canSave(kind, setting))
            Button(SettingsCopy.cancel) { editing = nil }
                .controlSize(.small)
            if store.changingSetting == key {
                ProgressView()
                    .controlSize(.small)
            }
        }
        if kind == .list {
            SettingsCaption(SettingsCopy.separateEntries)
        }
    }

    // MARK: - Changes

    private var canChange: Bool {
        app.cliContext != nil && !store.isWritingConfig
    }

    private func boolBinding(_ key: String, _ setting: ConfigValueDocument) -> Binding<Bool> {
        Binding(
            get: { setting.value == .bool(true) },
            set: { on in
                guard let context = app.cliContext else { return }
                Task { await store.setGlobal(key, values: [on ? "true" : "false"], in: context) }
            })
    }

    /// An empty value can only be removed, and only when config.toml sets it.
    private func canSave(_ kind: ConfigKey.Kind, _ setting: ConfigValueDocument) -> Bool {
        !Self.values(of: draft, kind).isEmpty || setting.layer?.isConfigFile == true
    }

    private func save(_ key: String, _ kind: ConfigKey.Kind, _ setting: ConfigValueDocument) {
        guard let context = app.cliContext, canChange, canSave(kind, setting) else { return }
        let values = Self.values(of: draft, kind)
        Task {
            let done =
                values.isEmpty
                ? await store.unsetGlobal(key, in: context) : await store.setGlobal(key, values: values, in: context)
            if done {
                editing = nil
            }
        }
    }

    private func unset(_ key: String) {
        guard let context = app.cliContext else { return }
        Task { await store.unsetGlobal(key, in: context) }
    }

    // MARK: - Values

    /// What the row shows: a list comma-separated, `Not set` for nothing.
    static func shown(_ value: JSONValue) -> String {
        value == .null ? SettingsCopy.notSet : value.shown
    }

    /// The text an edit starts from.
    static func draft(of value: JSONValue) -> String {
        value == .null ? "" : value.shown
    }

    /// The arguments `config` gets: one per comma-separated entry of a list, else the trimmed text; empty for
    /// nothing typed.
    static func values(of draft: String, _ kind: ConfigKey.Kind) -> [String] {
        switch kind {
        case .list:
            return draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case .bool, .text:
            let text = draft.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : [text]
        }
    }

    /// Unset only for a key config.toml sets and does not enforce: `--unset` of a key `policy.enforce` lists always
    /// fails (`policy.enforce lists …, which policy does not set`), so the row says to lift it first.
    static func canUnset(_ layer: ConfigLayer?) -> Bool {
        layer == .configFile
    }

    /// Why a row cannot be changed here; nil when it can.
    static func readOnlyReason(_ key: String, _ setting: ConfigValueDocument) -> String? {
        if setting.layer == .environment {
            return SettingsCopy.environmentNote(variable: ConfigKey.environmentVariable(for: key))
        }
        // `policy.enforce` from the system file is the organisation's list, not one the user's file holds.
        if setting.layer == .systemEnforced || (key == "policy.enforce" && setting.layer == .system) {
            return SettingsCopy.systemEnforcedNote
        }
        if ConfigKey.mayHoldCredentials(key), case .array(let entries) = setting.value,
            entries.contains(where: { $0.shown.contains("://") })
        {
            return SettingsCopy.redactedSourcesNote
        }
        return nil
    }
}
