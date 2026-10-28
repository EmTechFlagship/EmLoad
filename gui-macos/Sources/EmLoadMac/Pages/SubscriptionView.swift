import SwiftUI

struct SubscriptionView: View {
    private let patreonURL = URL(string: "https://www.patreon.com/cw/EmAppleFlagship/membership")!
    private let callbackURL = "https://emload-patreon.ios11emiry.workers.dev/patreon/callback"
    @EnvironmentObject private var membership: PatreonSubscription

    var body: some View {
        PageScroll {
            VStack(alignment: .leading, spacing: 8) {
                Label("Subscription", systemImage: "crown.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .textCase(.uppercase)
                Text("Choose your EmLoad plan")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(EmTheme.label)
                Text("Support EmLoad through the EmAppleFlagship Patreon page. Your Patreon membership is the source of subscription access.")
                    .font(.system(size: 14))
                    .foregroundStyle(EmTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    planCard(
                        name: "EmLoad+",
                        tier: "Em Basic membership",
                        benefits: [
                            ("JIT tools", "Enable just-in-time compilation for compatible sideloaded apps."),
                            ("EmLoadStore Companion", "Set up the companion on connected iPhone and iPad devices."),
                        ]
                    )
                    subscribeButton
                }

                VStack(spacing: 12) {
                    planCard(
                        name: "EmLoad Pro",
                        tier: "Em Pro membership",
                        benefits: [
                            ("Plus benefits", "Includes EmLoad Plus JIT tools."),
                            ("EmLoadStore Companion", "Includes sideloading the companion to your iPhone or iPad."),
                        ]
                    )
                    subscribeButton
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Connect your Patreon membership")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EmTheme.label)
                Text("Subscribe to Em Basic for EmLoad Plus or Em Pro for EmLoad Pro, then connect your Patreon account to check your tier.")
                    .font(.system(size: 13))
                    .foregroundStyle(EmTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: patreonURL) {
                    Label("View membership tiers on Patreon", systemImage: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(EmTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(EmTheme.accent)

                HStack(spacing: 12) {
                    Button {
                        membership.connect()
                    } label: {
                        Label(membership.isConnecting ? "Waiting for Patreon…" : "Connect Patreon", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(EmTheme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .disabled(membership.isConnecting)
                    .foregroundStyle(EmTheme.accent)

                    if membership.isConnecting {
                        Button("Cancel") { membership.cancel() }
                            .buttonStyle(.plain)
                            .foregroundStyle(EmTheme.secondary)
                    }
                }
                Text(membership.message)
                    .font(.system(size: 12))
                    .foregroundStyle(EmTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Patreon OAuth callback URL")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(EmTheme.secondary)
                    Text(callbackURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(EmTheme.label)
                        .textSelection(.enabled)
                    Text("Register this URL in the Patreon client settings. The Worker keeps the Patreon client secret server-side and checks your current membership tier.")
                        .font(.system(size: 11))
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .background(EmTheme.label.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var subscribeButton: some View {
        Link(destination: patreonURL) {
            Label("Subscribe with Patreon", systemImage: "arrow.up.right.square")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(red: 1.0, green: 0.27, blue: 0.34), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
    }

    private func planCard(name: String, tier: String, benefits: [(String, String)]) -> some View {
        VStack(spacing: 0) {
            Text(name)
                .font(.system(size: 29, weight: .bold))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 23, style: .continuous))

            VStack(alignment: .leading, spacing: 15) {
                Text(tier)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(EmTheme.label)
                Text("on EmAppleFlagship Patreon")
                    .font(.system(size: 12))
                    .foregroundStyle(EmTheme.secondary)

                Rectangle()
                    .fill(EmTheme.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 2)

                Text("INCLUDED BENEFITS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(EmTheme.tertiary)

                ForEach(Array(benefits.enumerated()), id: \.offset) { _, benefit in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: benefit.0 == "JIT tools" ? "bolt.fill" : "app.badge")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.yellow)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(benefit.0)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(EmTheme.label)
                            Text(benefit.1)
                                .font(.system(size: 11))
                                .foregroundStyle(EmTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, minHeight: 340, maxHeight: 340)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .strokeBorder(EmTheme.hairline, lineWidth: 1)
        }
    }
}
