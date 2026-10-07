import SwiftUI

struct OrdersView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.ordersPath) {
            Group {
                if store.orders.isEmpty {
                    ContentUnavailableView(
                        "No orders yet", systemImage: "bag",
                        description: Text("Pick a restaurant on Home to place one."))
                } else {
                    List(store.orders) { order in
                        NavigationLink(value: order.id) { OrderRow(order: order) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Orders")
            .navigationDestination(for: String.self) { OrderDetailView(orderId: $0) }
            .refreshable { await store.refreshOrders() }
        }
    }
}

private struct OrderRow: View {
    let order: Order
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            CuisineIcon(cuisine: store.restaurant(order.restaurantId)?.cuisine ?? "", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.restaurant(order.restaurantId)?.name ?? "Order").font(.headline)
                Text(order.status.title).font(.subheadline)
                    .foregroundStyle(order.status.isClosed ? Color.secondary : Color.brand)
            }
            Spacer()
            if order.isPickup, let plan = order.pickup, !order.status.isClosed, order.status != .ready {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Pickup").font(.caption).foregroundStyle(.secondary)
                    Text(plan.shouldWait ? "Leave \(Format.time(plan.leaveAt))" : "Leave now")
                        .font(.subheadline.bold())
                }
            } else if let eta = order.currentEta, !order.status.isClosed {
                Text(Format.minutes(eta.etaMinutes)).font(.subheadline.bold())
            }
        }
        .padding(.vertical, 4)
    }
}
