import SwiftUI

/// BarMade Merchant: the kitchen's view of the BarMade API — tickets from
/// the web app and the iPhone app, batch stock, menu and expiry alerts.
@main
struct MerchantApp: App {
    @State private var store = MerchantStore()

    var body: some Scene {
        WindowGroup {
            BarMadeRootView()
                .environment(store)
                .task { await store.start() }
        }
    }
}
