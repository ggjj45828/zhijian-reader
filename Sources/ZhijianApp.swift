import SwiftUI

@main
struct ZhijianApp: App {
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .preferredColorScheme(store.theme == .night ? .dark : .light)
                .tint(store.theme.tint)
        }
    }
}
