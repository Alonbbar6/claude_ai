import SwiftUI

struct OrderDetailView: View {
    let orderId: String
    @Environment(AppStore.self) private var store

    private var order: Order? { store.orders.first { $0.id == orderId } }

    var body: some View {
        ScrollView {
            if let order {
                VStack(spacing: 16) {
                    if order.isPickup {
                        PickupHeader(order: order)
                        if let plan = order.pickup, !order.status.isClosed {
                            PickupCard(order: order, plan: plan)
                        }
                        StatusTimeline(status: order.status, steps: order.timeline)
                    } else {
                        EtaHeader(order: order)
                        StatusTimeline(status: order.status, steps: order.timeline)
                        RouteCard(route: order.route)
                        if let plan = order.dispatch { DispatchCard(plan: plan) }
                    }
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
        // Pickup orders re-plan from the phone's location each time.
        .task {
            while !Task.isCancelled {
                if let o = order, o.isPickup, !o.status.isClosed {
                    store.location.start()
                    await store.refreshPickupPlan(orderId)
                } else {
                    await store.refreshOrder(orderId)
                }
                if order?.status.isClosed == true { break }
                try? await Task.sleep(for: .seconds(order?.isPickup == true ? 15 : 3))
            }
        }
        // ...and immediately when the customer has moved.
        .task(id: store.location.movementKey) {
            guard let o = order, o.isPickup, !o.status.isClosed, store.location.coordinate != nil else { return }
            await store.refreshPickupPlan(orderId)
        }
        .onDisappear { store.location.stop() }
    }
}

// MARK: - Pickup

private struct PickupHeader: View {
    let order: Order

    var body: some View {
        VStack(spacing: 8) {
            switch order.status {
            case .collected:
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Color.brand)
                Text("Enjoy your meal").font(.title.bold())
                    .accessibilityIdentifier("collected-header")
            case .cancelled:
                Image(systemName: "xmark.octagon.fill").font(.system(size: 44)).foregroundStyle(.red)
                Text("Cancelled").font(.title.bold())
            case .ready:
                Image(systemName: "bag.fill").font(.system(size: 40)).foregroundStyle(Color.brand)
                Text("Your food is ready").font(.title.bold())
                    .accessibilityIdentifier("ready-header")
                if let plan = order.pickup { Text(plan.message).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            default:
                if let plan = order.pickup {
                    LeaveCountdown(plan: plan)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// Ticks every second so "Leave in 7:42" stays live between re-plans.
private struct LeaveCountdown: View {
    let plan: PickupPlan

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = plan.leaveAt.timeIntervalSince(context.date)
            VStack(spacing: 8) {
                if plan.shouldWait && remaining > 0 {
                    Text("Leave in").foregroundStyle(.secondary)
                    Text(countdown(remaining))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("leave-countdown")
                    Text("at \(Format.time(plan.leaveAt)) · arrive ~\(Format.time(plan.arriveAt))")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("Leave now")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(plan.foodWaitMin > 5 ? Color.orange : Color.brand)
                        .accessibilityIdentifier("leave-now")
                    Text(plan.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PickupCard: View {
    let order: Order
    let plan: PickupPlan
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        Card(title: "Pickup plan", systemImage: "takeoutbag.and.cup.and.straw") {
            Picker("Getting there", selection: Binding(
                get: { order.pickupMode },
                set: { m in Task { await store.refreshPickupPlan(order.id, mode: m) } })
            ) {
                ForEach(TravelMode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)

            InfoRow(label: order.status == .ready ? "Ready since" : "Food ready",
                    value: order.status == .ready ? Format.time(plan.readyAt) : "~\(Format.time(plan.readyAt)) (by \(Format.time(plan.readyBy)))")
            InfoRow(label: "Your trip",
                    value: "\(Format.km(plan.distanceKm)) · \(Format.minutes(plan.tripMin))")
            InfoRow(label: "Leave", value: plan.shouldWait ? Format.time(plan.leaveAt) : "Now")
            InfoRow(label: "Arrive", value: "~\(Format.time(plan.arriveAt))")
            if plan.foodWaitMin > 5 {
                Label("Food will wait ~\(Format.minutes(plan.foodWaitMin)) for you", systemImage: "thermometer.low")
                    .font(.caption).foregroundStyle(.orange)
            } else if plan.yourWaitMin > 1 {
                Label("You may wait ~\(Format.minutes(plan.yourWaitMin)) at the counter", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Timed to arrive as your food comes out", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Color.brand)
            }

            HStack {
                Button {
                    if let url = directionsURL { openURL(url) }
                } label: {
                    Label("Get directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)

                if order.status == .ready {
                    Button {
                        Task { await store.perform("collect", on: order.id) }
                    } label: {
                        Text("I've picked it up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Apple Maps turn-by-turn to the restaurant in the chosen mode.
    private var directionsURL: URL? {
        guard let r = store.restaurant(order.restaurantId) else { return nil }
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(r.lat),\(r.lng)"),
            URLQueryItem(name: "dirflg", value: order.pickupMode == .driving ? "d" : "w"),
            URLQueryItem(name: "q", value: r.name),
        ]
        return c?.url
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
    let steps: [OrderStatus]

    private var currentIndex: Int { steps.firstIndex(of: status) ?? -1 }

    var body: some View {
        Card(title: "Status", systemImage: "list.bullet") {
            if status == .cancelled {
                Label(OrderStatus.cancelled.title, systemImage: OrderStatus.cancelled.icon).foregroundStyle(.red)
            } else {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
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
                if !order.isPickup {
                    Button("Demand spike") { Task { await store.perform("refresh-eta", on: order.id) } }
                }
                Button("Cancel", role: .destructive) { Task { await store.perform("cancel", on: order.id) } }
            }
            .buttonStyle(.bordered)
            .font(.subheadline)
            .disabled(order.status.isClosed)
        }
    }
}
