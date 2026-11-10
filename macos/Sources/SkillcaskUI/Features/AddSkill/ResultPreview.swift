import SkillcaskCore
import SkillcaskDomain
import SwiftUI

/// The Add Skill sheet's preview pane (AddSkill board, right of the results): the selection's `info` as name and
/// source, license, installs, newest and what will be installed, the description, the provided skills, the
/// version rule and the agents it will be linked into. The failure of the preview or of the last Add sits on top
/// (AddSkill-States failures), with the action the CLI's hint suggests.
///
/// Gated on the CLI (`Capabilities`): the provided skills are checkboxes only with `add --skill`, read-only and all
/// ticked otherwise, with a line that says what Add does (`SearchStore.skillsNote`); a result that names one skill
/// lists that skill, read-only. The name-clash rename field shows only with `add --rename` (on 0.9.4 the clash is
/// the CLI's error and hint after Add).
struct ResultPreview: View {
    @Bindable var search: SearchStore
    /// The last Add's failure as the sheet words it; nil when none is on screen.
    let addFailure: UserMessage?
    /// Adds again (Retry on a network failure of Add).
    let onRetryAdd: () -> Void

    @State private var showsDetails = false

    var body: some View {
        switch search.preview {
        case .none:
            VStack(spacing: Spacing.m) {
                failureBlock
                Text(AddSkillCopy.noSelection)
                    .font(Font.Token.callout)
                    .foregroundStyle(Color.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(Spacing.l)
        case .loading:
            Spinner(label: AddSkillCopy.loadingPreview)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.cardGap) {
                failure(message, onRetry: search.retryPreview, offersFollowUp: true)
                Spacer(minLength: 0)
            }
            .padding(Spacing.l)
        case .loaded(let info):
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    failureBlock
                    if let warning = search.entryWarning {
                        FailureBanner(warning)
                    }
                    summary(info)
                    if let clash = search.clash {
                        clashBlock(clash)
                    }
                    if !search.providedSkills.isEmpty {
                        skills(search.providedSkills)
                    }
                    if let base = search.ruleBase {
                        ruleRow(base)
                    }
                    if !agents.isEmpty {
                        HStack(spacing: Spacing.s) {
                            StatusDot(.ok)
                            Text(AddSkillCopy.linkedInto(agents))
                                .font(Font.Token.callout)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                .padding(.vertical, Size.cardPaddingH)
                .padding(.horizontal, Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Summary

    private func summary(_ info: InfoDocument) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(info.package ?? search.selectedSpec?.base ?? "")
                    .font(Font.Token.mono)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                if let source = search.selectedResult?.source ?? info.source {
                    Pill(source: SourceKind(parsing: source))
                }
            }
            meta(info)
                .font(Font.Token.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let description = info.description {
                Text(description)
                    .font(Font.Token.callout)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    /// `MIT · 4.1k installs · newest 4.3.0 · 4.2.0 will be installed; 4.3.0 is inside your 3 d minimum release age`.
    private func meta(_ info: InfoDocument) -> Text {
        let lead = Self.metaParts(info, installs: search.selectedResult?.installs).joined(separator: " · ")
        // The add that just succeeded locked the package; its `info` still reads as before the add.
        let note =
            search.justAdded == nil
            ? Self.installNote(
                info, minimumAge: minimumAge, pinned: search.selectedSpec?.pinned != nil, hasEntry: search.hasEntry)
            : nil
        guard let note else {
            return Text(lead).foregroundStyle(Color.textSecondary)
        }
        let separator = lead.isEmpty ? "" : " · "
        return Text(lead + separator).foregroundStyle(Color.textSecondary)
            + Text(note).foregroundStyle(Color.statusWarningText)
    }

    /// License, installs and the newest version, in the board's order.
    static func metaParts(_ info: InfoDocument, installs: Int?) -> [String] {
        var parts: [String] = []
        if !info.license.isEmpty {
            parts.append(info.license.joined(separator: ", "))
        }
        if let installs {
            parts.append(AddSkillCopy.installs(installs))
        }
        if let newest = info.versions.first {
            parts.append(AddSkillCopy.newest(newest))
        }
        return parts
    }

    /// The warning after the meta line when `add` would not install the newest version (`info`'s `version` is
    /// the one `add` picks, unless the package is already locked). The minimum release age is named only when it
    /// is the one cause left: `info` then selected with the constraint `*` (no pin typed, no skills.toml entry)
    /// and the newest version is a stable release, so neither a constraint nor the stability filter held it back
    /// (`registry::select` in `info`). Otherwise the neutral "<version> will be installed".
    static func installNote(_ info: InfoDocument, minimumAge: String?, pinned: Bool, hasEntry: Bool) -> String? {
        guard info.locked != true, let version = info.version, let newest = info.versions.first, newest != version
        else { return nil }
        let newestIsStable = VersionRule.Base(newest).map { !$0.text.contains("-") && !$0.text.contains("+") } ?? false
        guard let minimumAge, !pinned, !hasEntry, newestIsStable else { return AddSkillCopy.willInstall(version) }
        return AddSkillCopy.cooldown(install: version, newest: newest, age: minimumAge)
    }

    private var minimumAge: String? {
        search.knownMinimumAge
    }

    private var agents: [String] {
        search.store.snapshot?.targets?.entries.map(ShellCopy.agentName) ?? []
    }

    // MARK: - Provided skills

    private func skills(_ skills: [InfoDocument.Skill]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.inline) {
            Text(AddSkillCopy.skillsHeading(selected: search.chosenSkills.count))
                .font(Font.Token.calloutSemibold)
                .foregroundStyle(Color.textPrimary)
            ForEach(skills, id: \.name) { skill in
                Toggle(isOn: chosen(skill.name)) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(skill.name)
                            .font(Font.Token.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                        if let description = skill.description {
                            Text(description)
                                .font(Font.Token.callout)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .tint(Color.accent)
                .disabled(!search.canChooseSkills || search.selectedSpec?.skill != nil)
                .padding(.vertical, Spacing.s)
                .padding(.horizontal, Spacing.cardGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                        .strokeBorder(Color.separator, lineWidth: Size.hairline))
            }
            if let note = search.skillsNote {
                Text(note)
                    .font(Font.Token.caption)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func chosen(_ skill: String) -> Binding<Bool> {
        Binding(
            get: { !search.excludedSkills.contains(skill) },
            set: { isOn in
                if isOn {
                    search.excludedSkills.remove(skill)
                } else {
                    search.excludedSkills.insert(skill)
                }
            })
    }

    // MARK: - Version rule

    private func ruleRow(_ base: VersionRule.Base) -> some View {
        HStack(spacing: Spacing.cardGap) {
            Text(AddSkillCopy.versionRule)
                .font(Font.Token.calloutSemibold)
                .foregroundStyle(Color.textPrimary)
            VersionRuleControl(
                base: base, options: search.ruleOptions,
                rule: Binding(get: { search.effectiveRule }, set: { search.rule = $0 }), branch: $search.branch,
                constraint: { $0.constraint(for: base) },
                keptLabel: search.keptConstraint == nil ? nil : AddSkillCopy.keptRule,
                keptConstraint: search.keptConstraint)
            Text(AddSkillCopy.ruleNote(rule: search.effectiveRule, version: base.exact))
                .font(Font.Token.caption)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
        }
    }

    // MARK: - Name clash

    private func clashBlock(_ clash: SearchStore.NameClash) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            FailureBanner(
                ErrorCopy.nameClash(
                    existing: clash.skill, existingPackage: clash.existingPackage,
                    newPackage: search.selectedSpec?.package ?? ""))
            Text(AddSkillCopy.renameLabel)
                .font(Font.Token.callout)
                .foregroundStyle(Color.textSecondary)
            TextField(AddSkillCopy.renameLabel, text: $search.renameTo, prompt: Text(clash.suggestion))
                .textFieldStyle(.roundedBorder)
                .font(Font.Token.mono)
                .frame(width: Self.renameWidth)
            let name = search.renameTo.isEmpty ? clash.suggestion : search.renameTo
            FailureBanner.styled(AddSkillCopy.renameNote(name), fragment: name, font: Font.Token.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    /// AddSkill-States: the rename field is `width: 300px`.
    static let renameWidth: CGFloat = 300

    // MARK: - Failures

    @ViewBuilder private var failureBlock: some View {
        if let addFailure {
            failure(addFailure, onRetry: onRetryAdd, offersFollowUp: false)
        }
    }

    /// The banner with Details (the transcript, disclosed below it), then the action the failure suggests:
    /// search for the name instead when nothing was found, search the allowed sources after a policy refusal. Only
    /// the preview's failures offer it: they are the ones that say the package cannot be had as typed.
    private func failure(_ message: UserMessage, onRetry: @escaping () -> Void, offersFollowUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cardGap) {
            FailureBanner(
                message, onDetails: message.details == nil ? nil : { showsDetails.toggle() },
                onRetry: FailureBanner.showsRetry(message) ? onRetry : nil)
            if showsDetails, let details = message.details {
                Text(details)
                    .font(Font.Token.monoSmall)
                    .foregroundStyle(Color.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offersFollowUp, let spec = search.selectedSpec, let action = Self.followUp(for: message) {
                Button(action == .searchAllowed ? AddSkillCopy.searchAllowedSources : searchLabel(spec)) {
                    search.query = AddSkillCopy.searchTerm(for: spec)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func searchLabel(_ spec: PackageSpec) -> String {
        AddSkillCopy.searchFor(AddSkillCopy.searchTerm(for: spec))
    }

    /// What a failure offers besides its banner's own buttons.
    enum FollowUp: Hashable {
        /// Not found (a plain problem): search for the name.
        case searchName
        /// A policy refusal: search the sources the policy allows.
        case searchAllowed
    }

    static func followUp(for message: UserMessage) -> FollowUp? {
        guard message.remedy == nil, !message.isIntegrity else { return nil }
        switch message.severity {
        case .warning: return .searchAllowed
        case .error: return .searchName
        case .neutral, .ok, .update: return nil
        }
    }
}
