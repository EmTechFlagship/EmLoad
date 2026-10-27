import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var library: AppLibrary

    var body: some View {
        #if os(macOS)
        MacLibraryView(library: library)
        #else
        CompanionView(library: library)
        #endif
    }
}

#if os(macOS)
private struct MacLibraryView: View {
    @ObservedObject var library: AppLibrary
    @State private var isImporterPresented = false

    var body: some View {
        NavigationSplitView {
            List {
                Label("Library", systemImage: "square.grid.2x2")
                    .foregroundStyle(.tint)
                Label("Signing & Devices", systemImage: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("EmLoadStore")
        } detail: {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your Library")
                            .font(.largeTitle.bold())
                        Text("Keep your IPA files together before signing and installing.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Import IPA", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Label {
                    Text("Personal-team signing and connected-device installation are not configured yet.")
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                if library.apps.isEmpty {
                    ContentUnavailableView(
                        "No IPAs yet",
                        systemImage: "shippingbox",
                        description: Text("Import an IPA to add it to your local library.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(library.apps) { app in
                            HStack(spacing: 12) {
                                Image(systemName: "app.dashed")
                                    .font(.title2)
                                    .foregroundStyle(.tint)
                                    .frame(width: 42, height: 42)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                        .font(.headline)
                                    Text("Imported \(app.importedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("IPA")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(.quaternary, in: Capsule())
                                Button(role: .destructive) {
                                    remove(app)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove IPA from library")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .padding(28)
            .frame(minWidth: 700, minHeight: 460)
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: importFiles
            )
            .alert(
                "EmLoadStore",
                isPresented: Binding(
                    get: { library.errorMessage != nil },
                    set: { if !$0 { library.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    library.errorMessage = nil
                }
            } message: {
                Text(library.errorMessage ?? "")
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                try library.importIPA(from: url)
            }
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }

    private func remove(_ app: ImportedIPA) {
        do {
            try library.remove(app)
        } catch {
            library.errorMessage = error.localizedDescription
        }
    }
}
#else
private struct CompanionView: View {
    @ObservedObject var library: AppLibrary
    @State private var selectedTab: AppTab = .home
    @State private var isPairingImporterPresented = false

    var body: some View {
        TabView(selection: $selectedTab) {
            home
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            libraryTab
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }
                .tag(AppTab.apps)

            devicesTab
                .tabItem { Label("Devices", systemImage: "iphone.gen3") }
                .tag(AppTab.devices)

            settingsTab
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(.indigo)
        .alert(
            "EmLoadStore",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                library.errorMessage = nil
            }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var home: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Good to see you")
                            .font(.largeTitle.bold())
                        Text("Your sideloading hub")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Label("HOST STATUS", systemImage: "server.rack")
                                .font(.caption.weight(.bold))
                                .tracking(1)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle()
                                .fill(.orange)
                                .frame(width: 8, height: 8)
                            Text("Not connected")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Text("Connect to EmLoadServer")
                            .font(.title2.bold())
                        Text("Pair your iPhone with the Mac host to get started.")
                            .foregroundStyle(.secondary)

                        Button {
                            selectedTab = .devices
                        } label: {
                            Label("Set up a device", systemImage: "arrow.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .padding(20)
                    .glassCard(cornerRadius: 28)

                    HStack(spacing: 12) {
                        StatCard(title: "APPS", value: "\(library.apps.count)", symbol: "square.grid.2x2")
                        StatCard(title: "DEVICES", value: "0", symbol: "iphone")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label("EmLoadStore", systemImage: "shippingbox.fill")
                        .font(.headline)
                }
            }
        }
    }

    private var libraryTab: some View {
        NavigationStack {
            Group {
                if library.apps.isEmpty {
                    ContentUnavailableView(
                        "No Apps Yet",
                        systemImage: "square.stack.3d.up",
                        description: Text("Apps signed by your Mac host will show up here.")
                    )
                } else {
                    List(library.apps) { app in
                        HStack(spacing: 14) {
                            Image(systemName: "app.dashed")
                                .font(.title2)
                                .foregroundStyle(.indigo)
                                .frame(width: 48, height: 48)
                                .glassCard(cornerRadius: 14)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name).font(.headline)
                                Text("Added \(app.importedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("My Apps")
        }
    }

    private var devicesTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 42))
                        .foregroundStyle(.indigo)
                        .frame(width: 88, height: 88)
                        .glassCard(cornerRadius: 26)

                    VStack(spacing: 8) {
                        Text("Pair your iPhone")
                            .font(.title2.bold())
                        Text("Connect to EmLoadServer on your Mac. The host creates a private pairing record that you can securely transfer to this device.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isPairingImporterPresented = true
                    } label: {
                        Label(
                            library.hasPairingRecord ? "Replace Pairing File" : "Import Pairing File",
                            systemImage: "lock.doc"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if library.hasPairingRecord {
                        Label("Pairing file imported and protected on this device", systemImage: "checkmark.shield.fill")
                            .font(.footnote)
                            .foregroundStyle(.green)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        SetupStep(number: "1", title: "Connect by USB", detail: "Plug your iPhone into the Mac and approve Trust on the device.")
                        SetupStep(number: "2", title: "Pair with the host", detail: "Run emloadserver pair on the Mac.")
                        SetupStep(number: "3", title: "Import the pairing file", detail: "Transfer the record securely, then import it here.")
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 24)

                    Label("Host connection and app signing are not implemented yet.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Devices")
            .fileImporter(
                isPresented: $isPairingImporterPresented,
                allowedContentTypes: [.propertyList],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    try library.importPairingRecord(from: url)
                } catch {
                    library.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var settingsTab: some View {
        NavigationStack {
            List {
                Section("Host") {
                    Label("EmLoadServer", systemImage: "desktopcomputer")
                    Text("Sign in with EmLoadServer on your Mac. The password is sent to Apple, is not saved, and the session stays in the Mac Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Run `emloadserver login --apple-id <email>` with the device connected by USB. EmLoadServer installs EmLoadStoreCompanion after sign-in.")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0")
                    Label("Open-source project", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private enum AppTab: Hashable {
    case home
    case apps
    case devices
    case settings
}

private struct StatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.indigo)
            Text(value)
                .font(.title.bold())
            Text(title)
                .font(.caption.weight(.semibold))
                .tracking(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 22)
    }
}

private struct SetupStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.indigo)
                .frame(width: 28, height: 28)
                .background(.indigo.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
#endif
