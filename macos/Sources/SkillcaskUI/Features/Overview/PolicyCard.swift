import SkillcaskDomain
import SwiftUI

/// The Policy card (Overview): `status.policy` as setting, value and where it was set, with `enforced` in the
/// warning colour, and the footnote explaining it. In a quiet project (Overview-States Healthy) each setting is
/// one line, `Minimum release age 0 h default`. The board's "Open config.toml" link is not drawn: Settings ›
/// Advanced has Open config.toml.
struct PolicyCard: View {
    let snapshot: ScopeSnapshot
    /// Overview-States Healthy: the compact one-line form.
    let isCompact: Bool

    var body: some View {
        CardContainer(title: OverviewCopy.policy) {
            if isCompact {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(snapshot.policy) { policy in
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                            Text(OverviewCopy.policyName(policy.kind))
                                .font(Font.Token.callout)
                                .foregroundStyle(Color.textPrimary)
                            Text(OverviewCopy.policyValue(policy))
                                .font(Font.Token.calloutSemibold)
                                .foregroundStyle(Color.textPrimary)
                            Text(policy.isEnforced ? OverviewCopy.enforcedOrigin(policy.origin) : policy.origin)
                                .font(Font.Token.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    CardTable(
                        headers: [OverviewCopy.setting, OverviewCopy.value, OverviewCopy.setIn],
                        rows: snapshot.policy.map(row))
                    if snapshot.policy.contains(where: \.isEnforced) {
                        Text(OverviewCopy.policyFootnote(snapshot.policy))
                            .font(Font.Token.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func row(_ policy: ScopeSnapshot.PolicyRow) -> [CardTable.Cell] {
        let value: CardTable.Cell =
            policy.isAllowedSources ? .mono(OverviewCopy.policyValue(policy)) : .text(OverviewCopy.policyValue(policy))
        let from: CardTable.Cell = policy.isEnforced ? .enforced(policy.origin) : .mono(policy.origin)
        return [.text(OverviewCopy.policyName(policy.kind)), value, from]
    }
}
