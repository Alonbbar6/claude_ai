import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            NavigationStack { RestaurantListView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppStore.Tab.home)

            OrdersView()
                .tabItem { Label("Orders", systemImage: "bag.fill") }
                .badge(store.activeOrderCount)
                .tag(AppStore.Tab.orders)

            NavigationStack { NotificationsView() }
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(store.unreadCount)
                .tag(AppStore.Tab.notifications)

            NavigationStack { AccountView() }
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(AppStore.Tab.account)
        }
        .tint(.brand)
        .sheet(isPresented: $store.showCart) { CartView() }
        .overlay(alignment: .top) {
            if let n = store.banner {
                NotificationBanner(notification: n)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture {
                        store.banner = nil
                        if let orderId = n.orderId {
                            store.selectedTab = .orders
                            store.ordersPath = [orderId]
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: store.banner?.id)
        .task(id: store.banner?.id) {
            guard store.banner != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            store.banner = nil
        }
    }
}
