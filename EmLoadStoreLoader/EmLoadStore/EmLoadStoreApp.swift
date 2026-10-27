import SwiftUI

@main
struct EmLoadStoreApp: App {
    @StateObject private var library = AppLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
        }
    }
}
