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
}

enum AppSection: String, CaseIterable, Identifiable {
    case devices
    case sideload
    case library
    case misc
    case account
    case settings
    case diagnostics

    var id: String { rawValue }

    /// Sections offered in the sidebar. The Misc Tweaks page stays implemented
    /// (and can still be selected with `EMLOAD_SECTION=misc`) but is hidden.
    static var visible: [AppSection] {
        allCases.filter { $0 != .misc }
    }

    var title: String {
        switch self {
        case .devices: return "Devices"
        case .sideload: return "Sideload"
        case .library: return "Library"
        case .misc: return "Misc Tweaks"
        case .account: return "Account"
        case .settings: return "Settings"
        case .diagnostics: return "Diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .devices:
            return "Phones and iPads visible to EmLoad over USB or Wi-Fi."
        case .sideload:
            return "Sign and install an .ipa with your own Apple ID. Signatures last seven days."
        case .library:
            return "Apps EmLoad has installed, with their remaining signature lifetime."
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
        case .devices: return "iphone"
        case .sideload: return "square.and.arrow.down"
        case .library: return "books.vertical"
        case .misc: return "wand.and.stars"
        case .account: return "person.crop.circle"
        case .settings: return "gearshape"
        case .diagnostics: return "stethoscope"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var section: AppSection = AppSection(
        rawValue: ProcessInfo.processInfo.environment["EMLOAD_SECTION"] ?? ""
    ) ?? .devices
    @State private var showLog = false

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()

            if let error = state.startupError {
                StartupFailureView(message: error)
            } else {
                shell
            }
        }
        .background(WindowConfigurator())
        .ignoresSafeArea()
        .frame(minWidth: 1_040, minHeight: 700)
        .task { await state.initialize() }
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
            SidebarView(section: $section)
                .frame(width: 238)

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)

            VStack(spacing: 0) {
                page
                Divider().opacity(0.25)
                StatusBar(showLog: $showLog)
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .devices: DevicesView()
        case .sideload: SideloadView()
        case .library: LibraryView()
        case .misc: MiscView()
        case .account: AccountView()
        case .settings: SettingsView()
        case .diagnostics: DiagnosticsView()
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
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text("Python engine")
                .foregroundStyle(.secondary)

            Button {
                showLog = true
            } label: {
                Image(systemName: "text.alignleft")
            }
            .buttonStyle(.plain)
            .help("Show the full engine log")
        }
        .font(.caption)
        .padding(.horizontal, 24)
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
