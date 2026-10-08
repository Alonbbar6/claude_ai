import SwiftUI

struct RootView: View {
    @Environment(CustomerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        if store.name == nil {
            WelcomeView()
        } else {
            TabView(selection: $store.selectedTab) {
                NavigationStack { MenuView() }
                    .tabItem { Label("Menu", systemImage: "fork.knife") }
                    .tag(CustomerStore.Tab.menu)
                OrdersView()
                    .tabItem { Label("Orders", systemImage: "receipt") }
                    .badge(store.activeOrder == nil ? 0 : 1)
                    .tag(CustomerStore.Tab.orders)
                NavigationStack { AccountView() }
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(CustomerStore.Tab.account)
            }
            .sheet(isPresented: $store.showCart) { CartView() }
        }
    }
}
