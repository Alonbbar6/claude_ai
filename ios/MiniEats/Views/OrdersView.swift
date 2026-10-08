import SwiftUI

struct OrdersView: View {
    @Environment(CustomerStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.ordersPath) {
            Group {
                if store.orders.isEmpty {
                    ContentUnavailableView(
                        "No orders yet", systemImage: "receipt",
                        description: Text("Add something from the menu to place one."))
                } else {
                    List(store.orders) { order in
                        NavigationLink(value: order.id) { OrderRow(order: order) }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Orders")
            .navigationDestination(for: String.self) { OrderTrackerView(orderId: $0) }
            .refreshable { await store.refreshOrders() }
        }
    }
}

private struct OrderRow: View {
    let order: BarMadeOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(order.displayNumber).font(.headline)
                Badge(text: orderStatusTitle(order.status), color: orderStatusColor(order.status))
                Spacer()
                Text(Format.money(order.total)).font(.subheadline.monospacedDigit())
            }
            Text(order.items.map { "\($0.quantity)× \($0.name)" }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                if let f = fulfillmentLabel(order.fulfillment, table: order.tableNumber) { Text(f).bold() }
                Text(Format.dateTime(order.createdAt))
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
