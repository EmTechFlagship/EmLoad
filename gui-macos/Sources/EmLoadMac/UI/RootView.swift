import AppKit
import SwiftUI

@main
struct EmLoadMacApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("EmLoad", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1_040, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NotificationCenter.default.post(name: .emloadCheckForUpdates, object: nil)
                }
                Button("Check Diagnostics") {
                    NotificationCenter.default.post(name: .emloadShowDiagnostics, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let emloadShowDiagnostics = Notification.Name("EmLoadShowDiagnostics")
    static let emloadCheckForUpdates = Notification.Name("EmLoadCheckForUpdates")
}

enum AppSection: String, CaseIterable, Identifiable {
    case subscription
    case plusBenefits
    case proBenefits
    case devices
    case storeSetup
    case store
    case sideload
    case library
    case jit
    case misc
    case account
    case settings
    case diagnostics

    var id: String { rawValue }

    /// Sections offered in the sidebar. Misc Tweaks stays implemented, and
    /// EmLoadStore Setup appears only while an iPhone or iPad is connected.
    @MainActor
    static func visible(deviceConnected: Bool, membership: PatreonSubscription) -> [AppSection] {
        allCases.filter { section in
            switch section {
            case .subscription:
                return false
            case .plusBenefits:
                return membership.normalizedTier == "plus"
            case .proBenefits:
                return membership.normalizedTier == "pro"
            case .misc:
                return false
            case .storeSetup:
                return deviceConnected && membership.canInstallEmLoadStore
            case .jit:
                return true
            default:
                return true
            }
        }
    }

    var title: String {
        switch self {
        case .subscription: return "Subscription"
        case .plusBenefits: return "EmLoad Plus"
        case .proBenefits: return "EmLoad Pro"
        case .devices: return "Devices"
        case .storeSetup: return "EmLoadStore Setup"
        case .store: return "Store"
        case .sideload: return "Sideload"
        case .library: return "Library"
        case .jit: return "JIT"
        case .misc: return "Misc Tweaks"
        case .account: return "Account"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .subscription:
            return "EmLoad Plus and EmLoad Pro memberships."
        case .plusBenefits:
            return "Manage your EmLoad Plus benefits."
        case .proBenefits:
            return "Manage your EmLoad Pro benefits."
        case .devices:
            return "Phones and iPads visible to EmLoad over USB or Wi-Fi."
        case .storeSetup:
            return "Sign in with EmLoadServer, install EmLoadStoreCompanion, and export a pairing record."
        case .store:
            return "Download an IPA and send it to Sideload."
        case .sideload:
            return "Sign and install an .ipa with your own Apple ID. Signatures last seven days."
        case .library:
            return "Apps EmLoad has installed, with their remaining signature lifetime."
        case .jit:
            return "Turn on just-in-time compilation for a sideloaded app until it quits."
        case .misc:
            return "SpringBoard, daemon and Liquid Glass tweaks applied through sparserestore."
        case .account:
            return "The Apple ID used for certificates, App IDs and provisioning profiles."
        case .settings:
            return "Connection, signing tools and EmSideStore auto-install."
        case .diagnostics:
            return "Check that Python, usbmuxd, Anisette and zsign are ready."
        }
    }

    var icon: String {
        switch self {
        case .subscription, .plusBenefits, .proBenefits: return "crown.fill"
        case .devices: return "iphone"
        case .storeSetup: return "app.badge"
        case .store: return "bag"
        case .sideload: return "square.and.arrow.down"
        case .library: return "square.grid.2x2"
        case .jit: return "bolt"
        case .misc: return "wand.and.stars"
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @StateObject private var membership = PatreonSubscription()
    @State private var section: AppSection = AppSection(
        rawValue: ProcessInfo.processInfo.environment["EMLOAD_SECTION"] ?? ""
    ) ?? .devices
    @State private var showLog = false
    @State private var sidebarVisible = true

    var body: some View {
        ZStack(alignment: .top) {
            EmTheme.window

            if let error = state.startupError {
                StartupFailureView(message: error)
            } else {
                shell
            }

            WindowDragArea()
                .frame(height: 38)
                .frame(maxWidth: .infinity)

            Text("EmLoad")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EmTheme.label)
                .padding(.top, 11)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            SidebarToggleButton(visible: $sidebarVisible)
                .padding(.leading, sidebarVisible ? 184 : 74)
                .padding(.top, 8)
        }
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
        .tint(EmTheme.accent)
        .ignoresSafeArea()
        .frame(minWidth: 1_040, minHeight: 700)
        .environmentObject(membership)
        .task { await state.initialize() }
        .task { await state.checkForAppUpdate() }
        .sheet(item: $state.availableUpdate) { update in
            UpdateSheet(update: update)
                .environmentObject(state)
        }
        .sheet(isPresented: $state.showLogin) {
            LoginSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $showLog) {
            LogSheet()
                .environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .emloadShowDiagnostics)) { _ in
            section = .diagnostics
        }
        .onReceive(NotificationCenter.default.publisher(for: .emloadCheckForUpdates)) { _ in
            Task { await state.checkForAppUpdate(interactive: true) }
        }
        .onChange(of: state.devices) { devices in
            if state.isReady, devices.isEmpty, section == .storeSetup {
                section = .devices
            }
        }
        .onChange(of: state.isReady) { ready in
            if ready, state.devices.isEmpty, section == .storeSetup {
                section = .devices
            }
        }
        .onChange(of: membership.tier) { tier in
            if tier?.lowercased() == "plus" {
                section = .plusBenefits
            } else if tier?.lowercased() == "pro" {
                section = .proBenefits
            } else if section == .plusBenefits || section == .proBenefits {
                section = .devices
            } else {
                reconcileSection()
            }
        }
        .onChange(of: membership.jitBenefitEnabled) { _ in reconcileSection() }
        .onChange(of: membership.emLoadStoreBenefitEnabled) { _ in reconcileSection() }
        .onAppear { reconcileSection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.shutdown()
        }
        .alert(
            "EmLoad",
            isPresented: Binding(
                get: { state.alertMessage != nil },
                set: { if !$0 { state.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                SidebarView(section: $section)
                    .environmentObject(membership)
                    .frame(width: 220)
                    .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(EmTheme.hairline)
                    .frame(width: 1)
            }

            VStack(spacing: 0) {
                page
                    .padding(.top, 34)
                Rectangle()
                    .fill(EmTheme.hairline)
                    .frame(height: 1)
                StatusBar(showLog: $showLog)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .subscription: SubscriptionView()
        case .plusBenefits: MembershipBenefitsView()
        case .proBenefits: MembershipBenefitsView()
        case .devices: DevicesView()
        case .storeSetup:
            if membership.canInstallEmLoadStore {
                EmLoadStoreSetupView()
            } else {
                MembershipBenefitsView()
            }
        case .store:
            IPAStoreView { path in
                state.pendingIPAPath = path
                section = .sideload
            }
        case .sideload: SideloadView()
        case .library: LibraryView()
        case .jit: JitView()
        case .misc: MiscView()
        case .account: AccountView()
        case .settings: SettingsView()
        case .diagnostics: DiagnosticsView()
        }
    }

    private func reconcileSection() {
        let visible = AppSection.visible(deviceConnected: !state.devices.isEmpty, membership: membership)
        guard !visible.contains(section) else { return }
        if membership.normalizedTier == "plus" {
            section = .plusBenefits
        } else if membership.normalizedTier == "pro" {
            section = .proBenefits
        } else {
            section = .devices
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Binding var showLog: Bool
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.isReady ? Color.green : Color.orange)
                .frame(width: 7, height: 7)

            Text(state.statusMessage)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(EmTheme.secondary)

            if state.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(state.busyMessage)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            }

            Spacer(minLength: 12)

            Text("emload \(state.engineVersion)")
                .monospacedDigit()
                .foregroundStyle(EmTheme.tertiary)

            Button {
                showLog = true
            } label: {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(EmTheme.secondary)
            }
            .buttonStyle(.plain)
            .help("Show the full engine log")
        }
        .font(.caption)
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
    }
}

// MARK: - Startup failure

struct StartupFailureView: View {
    let message: String
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack {
            GlassPanel(cornerRadius: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The EmLoad engine could not start")
                                .font(.title3.weight(.semibold))
                            Text("The SwiftUI shell is running, but the Python engine is offline.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(message)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                    HStack {
                        Button("Retry") { state.retryStartup() }
                            .emPrimaryButton()
                        Button("Quit") { NSApplication.shared.terminate(nil) }
                            .emSecondaryButton()
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: 720)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
