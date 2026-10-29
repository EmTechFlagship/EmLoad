import Foundation
import SwiftUI

private struct StoreSource: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let url: URL
}

private struct StoreApp: Identifiable {
    let id: String
    let name: String
    let bundleID: String
    let developer: String
    let subtitle: String
    let description: String
    let version: String
    let minimumOS: String
    let size: Int?
    let iconURL: URL?
    let downloadURL: URL?
    let sourceName: String
    let screenshots: [URL]
    let rating: Double?
    let reviewCount: Int?
    let reviews: [StoreReview]
    let category: String
}

private struct StoreReview: Identifiable {
    let id = UUID()
    let author: String
    let title: String
    let body: String
    let rating: Int?
}

struct IPAStoreView: View {
    @EnvironmentObject private var state: AppState

    let onTransfer: (String) -> Void

    @State private var apps: [StoreApp] = []
    @State private var query = ""
    @State private var loading = false
    @State private var downloadingID: String?
    @State private var status = "Loading trusted app sources…"
    @State private var failed = false
    @State private var customSources = Self.savedSources()
    @State private var showSourceManager = false
    @State private var selectedApp: StoreApp?
    @State private var selectedCategory = "All"
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    private static let builtInSources = [
        StoreSource(
            id: "altstore",
            name: "AltStore",
            url: URL(string: "https://mikevillarroel.github.io/mikebuilds-source/source.json")!
        ),
        StoreSource(
            id: "utm",
            name: "UTM",
            url: URL(string: "https://alt.getutm.app/")!
        ),
        StoreSource(
            id: "sidestore-community",
            name: "SideStore Community",
            url: URL(string: "https://community-apps.sidestore.io/sidecommunity.json")!
        ),
    ]

    private var sources: [StoreSource] { Self.builtInSources + customSources }

    private let columns = [GridItem(.adaptive(minimum: 310), spacing: 14)]

    private var filteredApps: [StoreApp] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.filter { app in
            let matchesSearch = term.isEmpty
                || app.name.localizedCaseInsensitiveContains(term)
                || app.bundleID.localizedCaseInsensitiveContains(term)
                || app.developer.localizedCaseInsensitiveContains(term)
                || app.subtitle.localizedCaseInsensitiveContains(term)
            let matchesCategory = selectedCategory == "All"
                || Self.categoryTitle(app.category) == selectedCategory
            return matchesSearch && matchesCategory
        }
    }

    private var categories: [String] {
        ["All"] + Array(Set(apps.map { Self.categoryTitle($0.category) })).sorted()
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var featuredApps: [StoreApp] {
        Array(filteredApps.prefix(8))
    }

    private static func categoryTitle(_ category: String) -> String {
        category.isEmpty ? "Other" : category
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    var body: some View {
        PageScroll {
            PageHeader(
                title: "Store",
                subtitle: "Browse apps from AltStore, UTM, and SideStore’s moderated community source."
            ) {
                searchControl
            }

            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(failed ? .red : EmTheme.secondary)
                Button {
                    Task { await loadCatalog() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(EmTheme.secondary)
                .disabled(loading)
                .help("Refresh app catalog")

                Button("Sources") { showSourceManager = true }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(EmTheme.secondary)
                    .help("Manage app sources")
                Spacer()
                if !apps.isEmpty {
                    Text("\(filteredApps.count) apps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(EmTheme.tertiary)
                }
            }

            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    ForEach(categories, id: \.self) { category in
                        Button {
                            selectedCategory = category
                        } label: {
                            VStack(spacing: 8) {
                                Text(category == "All" ? "For you" : category)
                                    .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .medium))
                                    .foregroundStyle(selectedCategory == category ? EmTheme.label : EmTheme.secondary)
                                Capsule()
                                    .fill(selectedCategory == category ? EmTheme.accent : .clear)
                                    .frame(height: 3)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)

            if !isSearching && !featuredApps.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selectedCategory == "All" ? "From your sources" : "\(selectedCategory) apps")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(EmTheme.label)
                        Spacer()
                        Text("\(featuredApps.count) apps")
                            .font(.caption)
                            .foregroundStyle(EmTheme.tertiary)
                    }
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(featuredApps) { app in
                                featuredCard(app)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            if filteredApps.isEmpty && !loading {
                EmptyState(
                    symbol: query.isEmpty ? "shippingbox" : "magnifyingglass",
                    title: query.isEmpty ? "No apps available" : "No matching apps",
                    message: query.isEmpty
                        ? "Refresh the catalog to try the app sources again."
                        : "Try another app name, bundle ID, or developer."
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(isSearching ? "Search results" : "All apps")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(EmTheme.label)
                        Spacer()
                        Text("\(filteredApps.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(EmTheme.tertiary)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(filteredApps) { app in
                            appCard(app)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .task { await loadCatalog() }
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: searchExpanded)
        .onChange(of: customSources) { updatedSources in
            Self.saveSources(updatedSources)
            Task { await loadCatalog() }
        }
        .sheet(isPresented: $showSourceManager) {
            StoreSourceManagerView(
                builtInSources: Self.builtInSources,
                customSources: $customSources,
                onAddSource: fetchSource
            )
            .frame(minWidth: 560, minHeight: 500)
        }
        .sheet(item: $selectedApp) { app in
            AppOverviewView(
                app: app,
                isDownloading: downloadingID == app.id,
                onGet: {
                    selectedApp = nil
                    Task { await download(app) }
                }
            )
            .frame(minWidth: 760, minHeight: 680)
        }
    }

    @ViewBuilder
    private var searchControl: some View {
        if searchExpanded {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(EmTheme.secondary)
                TextField("Search apps", text: $query)
                    .textFieldStyle(.plain)
                    .frame(width: 205)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(EmTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
                Button {
                    query = ""
                    searchFocused = false
                    searchExpanded = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(EmTheme.secondary)
                }
                .buttonStyle(.plain)
                .help("Collapse search")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                if #available(macOS 26.0, *) {
                    Capsule().fill(.clear)
                        .glassEffect(.regular.interactive(), in: Capsule())
                } else {
                    Capsule().fill(EmTheme.elevated)
                        .overlay(Capsule().strokeBorder(EmTheme.hairline, lineWidth: 1))
                }
            }
            .transition(.scale(scale: 0.92, anchor: .trailing).combined(with: .opacity))
        } else {
            Button {
                searchExpanded = true
                DispatchQueue.main.async { searchFocused = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(EmTheme.label)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                    .background {
                        if #available(macOS 26.0, *) {
                            Circle().fill(.clear)
                                .glassEffect(.regular.interactive(), in: Circle())
                        } else {
                            Circle().fill(EmTheme.elevated)
                                .overlay(Circle().strokeBorder(EmTheme.hairline, lineWidth: 1))
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Search apps")
            .transition(.scale(scale: 0.82).combined(with: .opacity))
        }
    }

    private func featuredCard(_ app: StoreApp) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    selectedApp = app
                } label: {
                    HStack(spacing: 10) {
                        appIcon(app.iconURL)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(EmTheme.label)
                                .lineLimit(1)
                            Text(app.developer.isEmpty ? app.sourceName : app.developer)
                                .font(.caption)
                                .foregroundStyle(EmTheme.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Text(app.subtitle.isEmpty ? app.description : app.subtitle)
                    .font(.caption)
                    .foregroundStyle(EmTheme.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

                HStack(spacing: 6) {
                    StatusPill(text: "v\(app.version.isEmpty ? "?" : app.version)")
                    if let rating = app.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.yellow)
                    }
                    Spacer(minLength: 0)
                    Button("Get") {
                        Task { await download(app) }
                    }
                    .emSecondaryButton()
                    .disabled(app.downloadURL == nil || downloadingID != nil)
                }
            }
            .frame(width: 245, alignment: .leading)
        }
        .frame(width: 285, alignment: .topLeading)
    }

    private func appCard(_ app: StoreApp) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    selectedApp = app
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            appIcon(app.iconURL)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(EmTheme.label)
                                    .lineLimit(1)
                                Text(app.developer.isEmpty ? app.bundleID : app.developer)
                                    .font(.caption)
                                    .foregroundStyle(EmTheme.secondary)
                                    .lineLimit(1)
                                Text(app.subtitle.isEmpty ? app.bundleID : app.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(EmTheme.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }

                        Text(app.description.isEmpty ? "No description provided." : app.description)
                            .font(.caption)
                            .foregroundStyle(EmTheme.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 7) {
                            StatusPill(text: "v\(app.version.isEmpty ? "?" : app.version)")
                            if !app.minimumOS.isEmpty { StatusPill(text: "iOS \(app.minimumOS)+") }
                            if let size = app.size { StatusPill(text: Self.formattedSize(size)) }
                            if let rating = app.rating {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.yellow)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                HStack {
                    Text(app.sourceName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(EmTheme.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        Task { await download(app) }
                    } label: {
                        Label(
                            downloadingID == app.id ? "Downloading…" : "Get",
                            systemImage: downloadingID == app.id ? "arrow.down.circle" : "arrow.down.to.line"
                        )
                    }
                    .emPrimaryButton()
                    .disabled(app.downloadURL == nil || downloadingID != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(15)
                    .foregroundStyle(EmTheme.secondary)
            }
            .frame(width: 56, height: 56)
            .background(EmTheme.elevated)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 26))
                .foregroundStyle(EmTheme.secondary)
                .frame(width: 56, height: 56)
                .background(EmTheme.elevated, in: RoundedRectangle(cornerRadius: 13))
        }
    }

    @MainActor
    private func loadCatalog() async {
        guard !loading else { return }
        loading = true
        failed = false
        status = "Refreshing app sources…"
        defer { loading = false }

        var loaded: [StoreApp] = []
        var failures: [String] = []
        for source in sources {
            do {
                var request = URLRequest(url: source.url)
                request.timeoutInterval = 25
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw StoreCatalogError.sourceUnavailable
                }
                loaded.append(contentsOf: try Self.parseApps(data, source: source))
            } catch {
                failures.append(source.name)
            }
        }

        var seen = Set<String>()
        apps = loaded.filter { seen.insert($0.bundleID.lowercased()).inserted }
        if apps.isEmpty {
            failed = true
            status = failures.isEmpty ? "No apps were found in the configured sources." : "Could not load the app sources. Check your connection and refresh."
        } else if failures.isEmpty {
            status = "Catalog updated from \(sources.count) app sources."
        } else {
            status = "Catalog loaded; \(failures.joined(separator: ", ")) could not be reached."
        }
    }

    @MainActor
    private func fetchSource(_ address: String) async throws -> StoreSource {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else {
            throw StoreCatalogError.invalidSourceURL
        }
        guard !sources.contains(where: { $0.url.absoluteString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            throw StoreCatalogError.sourceAlreadyAdded
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let manifestName = root["name"] as? String,
              root["apps"] is [[String: Any]] else {
            throw StoreCatalogError.invalidCatalog
        }

        let source = StoreSource(
            id: "custom:\(url.absoluteString)",
            name: manifestName,
            url: url
        )
        let parsedApps = try Self.parseApps(data, source: source)
        guard !parsedApps.isEmpty else {
            throw StoreCatalogError.sourceHasNoApps
        }
        return source
    }

    @MainActor
    private func download(_ app: StoreApp) async {
        guard downloadingID == nil, let url = app.downloadURL,
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              !host.isEmpty else { return }
        downloadingID = app.id
        failed = false
        status = "Downloading \(app.name)…"
        defer { downloadingID = nil }

        var downloadedFile: URL?
        do {
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https" else {
                throw StoreCatalogError.downloadFailed
            }
            let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard fileSize > 0, fileSize <= 2 * 1024 * 1024 * 1024 else {
                throw StoreCatalogError.invalidFileSize
            }

            let storeDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("EmLoad/Store", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let filename = Self.safeIPAName(app.name)
            let destination = storeDirectory.appendingPathComponent("\(UUID().uuidString.prefix(8))_\(filename)")
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            downloadedFile = destination

            _ = try await state.call("ipa.inspect", ["path": destination.path])
            state.appendLog("Downloaded and inspected \(app.name) IPA from \(app.sourceName).")
            status = "\(app.name) is ready. Opening Sideload…"
            onTransfer(destination.path)
            downloadedFile = nil
        } catch {
            if let downloadedFile { try? FileManager.default.removeItem(at: downloadedFile) }
            failed = true
            status = error.localizedDescription
        }
    }

    private static func parseApps(_ data: Data, source: StoreSource) throws -> [StoreApp] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["apps"] as? [[String: Any]] else {
            throw StoreCatalogError.invalidCatalog
        }

        return entries.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let bundleID = (entry["bundleIdentifier"] as? String) ?? (entry["appID"] as? String) else {
                return nil
            }
            let versions = entry["versions"] as? [[String: Any]] ?? []
            let versionData = versions.first(where: { $0["downloadURL"] is String }) ?? [:]
            let downloadString = (versionData["downloadURL"] as? String) ?? (entry["downloadURL"] as? String)
            let downloadURL = downloadString.flatMap(URL.init(string:))
            let iconString = entry["iconURL"] as? String
            let screenshotEntries = (entry["screenshotURLs"] as? [String])
                ?? (entry["screenshots"] as? [String])
                ?? []
            let reviewEntries = entry["reviews"] as? [[String: Any]] ?? []
            let reviews = reviewEntries.map { review in
                StoreReview(
                    author: (review["author"] as? String) ?? (review["name"] as? String) ?? "",
                    title: review["title"] as? String ?? "",
                    body: (review["body"] as? String) ?? (review["text"] as? String) ?? "",
                    rating: (review["rating"] as? NSNumber)?.intValue
                )
            }

            return StoreApp(
                id: "\(source.id):\(bundleID)",
                name: name,
                bundleID: bundleID,
                developer: entry["developerName"] as? String ?? "",
                subtitle: entry["subtitle"] as? String ?? "",
                description: entry["localizedDescription"] as? String ?? "",
                version: (versionData["version"] as? String)
                    ?? (entry["version"] as? String)
                    ?? (entry["absoluteVersion"] as? String)
                    ?? "",
                minimumOS: (versionData["minOSVersion"] as? String) ?? (entry["minOSVersion"] as? String) ?? "",
                size: (versionData["size"] as? NSNumber)?.intValue ?? (entry["size"] as? NSNumber)?.intValue,
                iconURL: iconString.flatMap(URL.init(string:)).flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil },
                downloadURL: downloadURL.flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil },
                sourceName: source.name,
                screenshots: screenshotEntries.compactMap(URL.init(string:)).filter { $0.scheme?.lowercased() == "https" },
                rating: (entry["rating"] as? NSNumber)?.doubleValue,
                reviewCount: (entry["reviewCount"] as? NSNumber)?.intValue
                    ?? (entry["ratingCount"] as? NSNumber)?.intValue,
                reviews: reviews,
                category: entry["category"] as? String ?? ""
            )
        }
    }

    private static func safeIPAName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let cleaned = String(base.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(cleaned.isEmpty ? "App" : cleaned).ipa"
    }

    fileprivate static func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func savedSources() -> [StoreSource] {
        guard let data = UserDefaults.standard.data(forKey: "IPAStoreCustomSources"),
              let sources = try? JSONDecoder().decode([StoreSource].self, from: data) else { return [] }
        return sources
    }

    private static func saveSources(_ sources: [StoreSource]) {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        UserDefaults.standard.set(data, forKey: "IPAStoreCustomSources")
    }
}

private struct StoreSourceManagerView: View {
    @Environment(\.dismiss) private var dismiss

    let builtInSources: [StoreSource]
    @Binding var customSources: [StoreSource]
    let onAddSource: @MainActor (String) async throws -> StoreSource

    @State private var address = ""
    @State private var isAdding = false
    @State private var message = "Add an AltStore or SideStore source URL."
    @State private var hasError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Sources")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(EmTheme.label)
                    Text("Add compatible AltStore or SideStore source URLs.")
                        .font(.callout)
                        .foregroundStyle(EmTheme.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .emSecondaryButton()
            }

            HStack(spacing: 10) {
                TextField("https://example.com/source.json", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .onSubmit { beginAdd() }
                Button {
                    beginAdd()
                } label: {
                    Label(isAdding ? "Adding…" : "Add Source", systemImage: "plus")
                }
                .emPrimaryButton()
                .disabled(isAdding || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(hasError ? .red : EmTheme.secondary)

            List {
                Section("Built-in sources") {
                    ForEach(builtInSources) { source in
                        sourceRow(source, removable: false)
                    }
                }
                Section("Added sources") {
                    if customSources.isEmpty {
                        Text("No sources added yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(customSources) { source in
                        sourceRow(source, removable: true)
                    }
                }
            }
            .listStyle(.inset)
        }
        .padding(22)
        .background(EmTheme.window)
    }

    private func sourceRow(_ source: StoreSource, removable: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(EmTheme.label)
                Text(source.url.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(EmTheme.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if removable {
                Button(role: .destructive) {
                    customSources.removeAll { $0.id == source.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help("Remove \(source.name)")
            }
        }
        .padding(.vertical, 3)
    }

    private func beginAdd() {
        guard !isAdding else { return }
        Task { await addSource() }
    }

    @MainActor
    private func addSource() async {
        isAdding = true
        hasError = false
        message = "Checking source…"
        defer { isAdding = false }
        do {
            let source = try await onAddSource(address)
            customSources.append(source)
            address = ""
            message = "Added \(source.name). Its apps will appear in Store."
        } catch {
            hasError = true
            message = error.localizedDescription
        }
    }
}

private struct AppOverviewView: View {
    let app: StoreApp
    let isDownloading: Bool
    let onGet: () -> Void

    var body: some View {
        PageScroll {
            PageHeader(title: app.name, subtitle: app.subtitle.isEmpty ? app.developer : app.subtitle) {
                Button(action: onGet) {
                    Label(isDownloading ? "Downloading…" : "Get", systemImage: "arrow.down.to.line")
                }
                .emPrimaryButton()
                .disabled(app.downloadURL == nil || isDownloading)
            }

            GlassPanel {
                HStack(alignment: .center, spacing: 16) {
                    overviewIcon
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.developer.isEmpty ? app.sourceName : app.developer)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(EmTheme.label)
                        Text(app.bundleID)
                            .font(.caption.monospaced())
                            .foregroundStyle(EmTheme.secondary)
                            .textSelection(.enabled)
                        HStack(spacing: 7) {
                            StatusPill(text: "Version \(app.version.isEmpty ? "?" : app.version)")
                            if !app.minimumOS.isEmpty { StatusPill(text: "iOS \(app.minimumOS)+") }
                            if let size = app.size { StatusPill(text: IPAStoreView.formattedSize(size)) }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if let rating = app.rating {
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 23, weight: .semibold))
                                .foregroundStyle(EmTheme.label)
                            stars(app.rating.map { Int($0.rounded()) } ?? 0)
                            Text(app.reviewCount.map { "\($0) ratings" } ?? "Source rating")
                                .font(.caption2)
                                .foregroundStyle(EmTheme.secondary)
                        } else {
                            Text(app.sourceName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(EmTheme.secondary)
                            Text("Source")
                                .font(.caption2)
                                .foregroundStyle(EmTheme.tertiary)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Description")
                Text(app.description.isEmpty ? "No description provided by the source." : app.description)
                    .font(.callout)
                    .foregroundStyle(EmTheme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !app.screenshots.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Previews")
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(Array(app.screenshots.enumerated()), id: \.offset) { _, url in
                                ScreenshotMockup(url: url)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Ratings & Reviews")
                if app.reviews.isEmpty {
                    Text(app.rating == nil
                         ? "This source does not provide ratings or written reviews for this app."
                         : "This source provides an overall rating, but no written reviews.")
                        .font(.callout)
                        .foregroundStyle(EmTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(app.reviews) { review in
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(review.title.isEmpty ? "Review" : review.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(EmTheme.label)
                                    Spacer()
                                    if let rating = review.rating { stars(rating) }
                                }
                                if !review.body.isEmpty {
                                    Text(review.body)
                                        .font(.callout)
                                        .foregroundStyle(EmTheme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !review.author.isEmpty {
                                    Text(review.author)
                                        .font(.caption)
                                        .foregroundStyle(EmTheme.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .background(EmTheme.window)
    }

    private var overviewIcon: some View {
        AsyncImage(url: app.iconURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "app.fill")
                .font(.system(size: 32))
                .foregroundStyle(EmTheme.secondary)
        }
        .frame(width: 76, height: 76)
        .background(EmTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func stars(_ count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < count ? "star.fill" : "star")
            }
        }
        .font(.caption2)
        .foregroundStyle(.yellow)
    }
}

private struct ScreenshotMockup: View {
    let url: URL

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 31, style: .continuous)
                .fill(Color.black)
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(EmTheme.elevated)
                    .overlay { ProgressView().controlSize(.small) }
            }
            .frame(width: 206, height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
            .padding(7)
            Capsule()
                .fill(Color.black)
                .frame(width: 66, height: 7)
                .padding(.top, 10)
        }
        .frame(width: 220, height: 434)
        .overlay {
            RoundedRectangle(cornerRadius: 31, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
}

private enum StoreCatalogError: LocalizedError {
    case invalidCatalog
    case sourceUnavailable
    case downloadFailed
    case invalidFileSize
    case invalidSourceURL
    case sourceAlreadyAdded
    case sourceHasNoApps

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: return "The app source returned an invalid catalog."
        case .sourceUnavailable: return "An app source could not be reached."
        case .downloadFailed: return "The app download did not complete successfully."
        case .invalidFileSize: return "The downloaded IPA is empty or larger than 2 GB."
        case .invalidSourceURL: return "Enter a valid HTTPS source URL."
        case .sourceAlreadyAdded: return "That source is already in your list."
        case .sourceHasNoApps: return "The source is valid, but it does not currently list any downloadable apps."
        }
    }
}
