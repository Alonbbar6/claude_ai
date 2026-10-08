import SwiftUI

/// BarMade for iPhone: order ahead from the kitchen the web app and the
/// merchant app share. Everything goes through the BarMade API.
@main
struct BarMadeApp: App {
    @State private var store = CustomerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.brand)
                .task { await store.start() }
        }
    }
}
