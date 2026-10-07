import SwiftUI

struct OrderDetailView: View {
    let orderId: String
    @Environment(AppStore.self) private var store

    private var order: Order? { store.orders.first { $0.id == orderId } }

    var body: some View {
        ScrollView {
            if let order {
                VStack(spacing: 16) {
                    EtaHeader(order: order)
                    StatusTimeline(status: order.status)
                    RouteCard(route: order.route)
                    if let plan = order.dispatch { DispatchCard(plan: plan) }
                    UpdatesCard(updates: store.notifications.filter { $0.orderId == orderId })
                    DemoControls(order: order)
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .navigationTitle(order.flatMap { store.restaurant($0.restaurantId)?.name } ?? "Order")
        .navigationBarTitleDisplayMode(.inline)
        // Poll as a fallback; WebSocket pushes also refresh the order instantly.
        .task {
            while !Task.isCancelled {
                await store.refreshOrder(orderId)
                if order?.status.isClosed == true { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct EtaHeader: View {
    let order: Order

    var body: some View {
        VStack(spacing: 8) {
            switch order.status {
            case .delivered:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Color.brand)
                Text("Delivered").font(.title.bold())
                    .accessibilityIdentifier("delivered-header")
            case .cancelled:
                Image(systemName: "xmark.octagon.fill").font(.system(size: 44)).foregroundStyle(.red)
                Text("Cancelled").font(.title.bold())
            default:
                Text("Arriving in").foregroundStyle(.secondary)
                Text(Format.minutes(order.currentEta?.etaMinutes ?? order.quotedEta?.etaMinutes ?? 0))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                if let eta = order.currentEta { RiskBadge(risk: eta.delayRisk) }
                if let quoted = order.quotedEta {
                    Text("Quoted \(Format.minutes(quoted.etaMinutes)) at checkout")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(.default, value: order.currentEta?.etaMinutes)
    }
}

private struct StatusTimeline: View {
    let status: OrderStatus

    private var currentIndex: Int { OrderStatus.timeline.firstIndex(of: status) ?? -1 }

    var body: some View {
        Card(title: "Status", systemImage: "list.bullet") {
            if status == .cancelled {
                Label(OrderStatus.cancelled.title, systemImage: OrderStatus.cancelled.icon).foregroundStyle(.red)
            } else {
                ForEach(Array(OrderStatus.timeline.enumerated()), id: \.offset) { index, step in
                    let done = index <= currentIndex
                    HStack(spacing: 12) {
                        Image(systemName: step.icon)
                            .frame(width: 28, height: 28)
                            .background(done ? Color.brand : Color(.tertiarySystemFill), in: Circle())
                            .foregroundStyle(done ? .white : .secondary)
                        Text(step.title)
                            .font(index == currentIndex ? .subheadline.bold() : .subheadline)
                            .foregroundStyle(done ? .primary : .secondary)
                    }
                }
            }
        }
    }
}

private struct RouteCard: View {
    let route: Route

    var body: some View {
        Card(title: "Route", systemImage: "map") {
            InfoRow(label: "Distance", value: Format.km(route.distanceKm))
            InfoRow(label: "Drive time", value: Format.minutes(route.durationMin))
            InfoRow(label: "Source", value: route.source == "google" ? "Google Maps (live traffic)" : "Estimated (no Google key)")
        }
    }
}

private struct DispatchCard: View {
    let plan: DispatchPlan

    var body: some View {
        Card(title: "Courier: \(plan.courierName)", systemImage: "bicycle") {
            InfoRow(label: "Distance to restaurant",
                    value: "\(Format.km(plan.courierToRestaurantKm)) · \(Format.minutes(plan.courierToRestaurantMin))")
            InfoRow(label: "Food ready", value: Format.time(plan.readyAt))
            InfoRow(label: "Courier leaves", value: Format.time(plan.dispatchAt))
            InfoRow(label: "Pickup", value: Format.time(plan.expectedPickupAt))
            InfoRow(label: "Delivery", value: Format.time(plan.expectedDeliveryAt))
            if plan.pickupDelayMin > 0 {
                Label("Food waits ~\(Format.minutes(plan.pickupDelayMin)) for the nearest courier",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("Timed to arrive as your food is ready", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Color.brand)
            }
        }
    }
}

private struct UpdatesCard: View {
    let updates: [AppNotification]

    var body: some View {
        Card(title: "Updates", systemImage: "bell") {
            if updates.isEmpty {
                Text("No updates yet").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(updates) { n in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(n.title).font(.subheadline.bold())
                        Spacer()
                        Text(Format.time(n.createdAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(n.body).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DemoControls: View {
    let order: Order
    @Environment(AppStore.self) private var store

    var body: some View {
        Card(title: "Demo controls", systemImage: "slider.horizontal.3") {
            Text("The backend moves orders forward every few seconds. Use these to drive it by hand.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Advance") { Task { await store.perform("advance", on: order.id) } }
                Button("Demand spike") { Task { await store.perform("refresh-eta", on: order.id) } }
                Button("Cancel", role: .destructive) { Task { await store.perform("cancel", on: order.id) } }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            .disabled(order.status.isClosed)
        }
    }
}
