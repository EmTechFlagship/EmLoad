import SwiftUI

struct MembershipBenefitsView: View {
    @EnvironmentObject private var membership: PatreonSubscription

    private var tierName: String {
        membership.normalizedTier == "pro" ? "EmLoad Pro" : "EmLoad Plus"
    }

    var body: some View {
        PageScroll {
            PageHeader(
                title: tierName,
                subtitle: "Choose which included benefits appear in your EmLoad sidebar. Changes are saved on this Mac."
            ) {
                Button {
                    membership.connect()
                } label: {
                    Label(membership.isConnecting ? "Waiting for Patreon…" : "Refresh Patreon", systemImage: "arrow.clockwise")
                }
                .emSecondaryButton()
                .disabled(membership.isConnecting)
            }

            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel("Your benefits")

                    Toggle(
                        "JIT tools",
                        isOn: Binding(
                            get: { membership.jitBenefitEnabled },
                            set: { membership.setJITBenefitEnabled($0) }
                        )
                    )
                    .font(.callout)
                    Text("Show JIT in the sidebar and let this account use it on compatible sideloaded apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if membership.normalizedTier == "plus" {
                        Divider().opacity(0.4)
                        Toggle(
                            "EmLoadStore Companion",
                            isOn: Binding(
                                get: { membership.emLoadStoreBenefitEnabled },
                                set: { membership.setEmLoadStoreBenefitEnabled($0) }
                            )
                        )
                        .font(.callout)
                        Text("Show the EmLoadStore setup section and allow companion installs to connected devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Divider().opacity(0.4)
                        Label("EmLoadStore Companion installs are unavailable with EmLoad Pro.", systemImage: "minus.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if !membership.message.isEmpty {
                        Text(membership.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Link(destination: URL(string: "https://www.patreon.com/cw/EmAppleFlagship/membership")!) {
                        Label("Manage Patreon membership", systemImage: "arrow.up.right.square")
                    }
                    .font(.callout.weight(.medium))
                }
            }

            Spacer(minLength: 0)
        }
    }
}
