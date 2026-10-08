import SwiftUI

/// Live order status, polled from the kitchen every 3 s like the web order
/// page, plus the pickup plan: the map, "leave in m:ss", and directions.
struct OrderTrackerView: View {
    let orderId: String
    @Environment(CustomerStore.self) private var store
    @Environment(\.openURL) private var openURL

    private var order: BarMadeOrder? { store.order(orderId) }
    private var plan: PickupPlan? { store.plans[orderId] }

    var body: some View {
        ScrollView {
            if let order {
                VStack(spacing: 16) {
                    if order.isOpen { TrackingMap(order: order) }
                    if order.isOpen { pickupHeader(order) }
                    header(order)
                    if order.status == "CANCELLED" {
                        Text("Cancelled")
                            .font(.headline).foregroundStyle(Color.warn)
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.warnTint, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("cancelled-header")
                    } else {
                        if order.isOpen { pickupCard(order) }
                        timeline(order)
                    }
                    items(order)
                    if order.isOpen { modelCard }
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(Color.cream)
        .navigationTitle(order.map { "Order \($0.displayNumber)" } ?? "Order")
        .navigationBarTitleDisplayMode(.inline)
        // Poll as a fallback for the kitchen's taps; re-plan from the phone's location each time.
        .task {
            store.location.start()
            while !Task.isCancelled {
                await store.refreshOrder(orderId)
                await store.refreshPlan(orderId)
                if order?.isClosed ?? true { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        // ...and immediately when the customer has moved.
        .task(id: store.location.movementKey) {
            if store.location.coordinate != nil { await store.refreshPlan(orderId) }
        }
    }

    // MARK: - Pickup

    /// The big number: leave in m:ss, leave now, or "your food is ready".
    private func pickupHeader(_ order: BarMadeOrder) -> some View {
        VStack(spacing: 8) {
            if order.status == "READY" {
                Image(systemName: "bag.fill").font(.system(size: 40)).foregroundStyle(Color.gold)
                Text("Your food is ready").font(.title.bold())
                    .accessibilityIdentifier("ready-header")
                if let plan { Text(plan.message).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            } else if let plan {
                LeaveCountdown(plan: plan)
                adjustment(order)
            } else {
                let est = store.readyEstimate(for: order)
                Text("Ready in about").foregroundStyle(.secondary)
                Text(Format.minutes(est.p50))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(store.location.isDenied
                     ? "Turn on location to see when to leave."
                     : "Finding your location to plan when to leave…")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// The quote the customer was given, how far the kitchen has drifted from it,
    /// and the chance it drifts further (the old app's ETA adjustment + delay risk).
    @ViewBuilder private func adjustment(_ order: BarMadeOrder) -> some View {
        if let risk = store.delayRisk(order) {
            let label = risk >= 0.6 ? "High delay risk" : risk >= 0.3 ? "Some delay risk" : "On time"
            let color: Color = risk >= 0.6 ? .red : risk >= 0.3 ? .warn : .fresh
            Badge(text: "\(label) · \(Int((risk * 100).rounded()))%", color: color)
                .padding(.top, 4)
                .accessibilityIdentifier("delay-risk")
        }
        if let quoted = store.quotedReady[order.id] {
            if let late = store.minutesLate(order) {
                Label("Running ~\(Format.minutes(late)) late · quoted ~\(Format.time(quoted)) at checkout", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.warn)
            } else {
                Text("Quoted ~\(Format.time(quoted)) at checkout").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pickupCard(_ order: BarMadeOrder) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pickup plan", systemImage: "takeoutbag.and.cup.and.straw").font(.headline)
            Picker("Getting there", selection: Binding(
                get: { store.mode },
                set: { m in Task { await store.setMode(m) } })
            ) {
                ForEach(TravelMode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)

            if let plan {
                InfoRow(label: order.status == "READY" ? "Ready since" : "Food ready",
                        value: order.status == "READY" ? Format.time(plan.readyAt) : "~\(Format.time(plan.readyAt)) (by \(Format.time(plan.readyBy)))")
                InfoRow(label: "Your trip", value: "\(Format.km(plan.distanceKm)) · \(Format.minutes(plan.tripMin)) \(plan.verb)")
                InfoRow(label: "Leave", value: plan.shouldWait ? Format.time(plan.leaveAt) : "Now")
                InfoRow(label: "Arrive", value: "~\(Format.time(plan.arriveAt))")
                if plan.foodWaitMin > PickupPlanner.freshHoldMin {
                    Label("Food will wait ~\(Format.minutes(plan.foodWaitMin)) for you", systemImage: "thermometer.low")
                        .font(.caption).foregroundStyle(Color.warn)
                } else if plan.yourWaitMin > 1 {
                    Label("You may wait ~\(Format.minutes(plan.yourWaitMin)) at the counter", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Timed to arrive as your food comes out", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(Color.fresh)
                }
                Text(plan.routeSource == "apple" ? "Travel time from Apple Maps" : "Travel time estimated from distance")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                let est = store.readyEstimate(for: order)
                InfoRow(label: "Food ready", value: "~\(Format.minutes(est.p50)) (by \(Format.minutes(est.p90)))")
            }

            Button {
                if let url = directionsURL { openURL(url) }
            } label: {
                Label("Get directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.gold)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
    }

    /// Apple Maps turn-by-turn to the restaurant in the chosen mode.
    private var directionsURL: URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(store.restaurantCoordinate.latitude),\(store.restaurantCoordinate.longitude)"),
            URLQueryItem(name: "dirflg", value: store.mode == .driving ? "d" : "w"),
            URLQueryItem(name: "q", value: store.restaurant.name),
        ]
        return c?.url
    }

    /// What the estimate is based on, so the number isn't a black box.
    private var modelCard: some View {
        let m = store.model
        return VStack(alignment: .leading, spacing: 6) {
            Label("How the estimate works", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
            Text("Kitchen time comes from each dish's recipe, how many tickets the kitchen has open right now (\(Int(store.kitchenBusy))) and the time of day, tuned to how this kitchen actually timed its past orders. We plan your arrival for the 75th percentile so you rarely wait at the counter.")
                .font(.caption).foregroundStyle(.secondary)
            InfoRow(label: "Orders learned from", value: "\(m.sampleCount)")
            InfoRow(label: "Kitchen pace vs. typical", value: String(format: "%.0f%%", m.kitchenFactor * 100))
            if let mae = m.meanAbsErrorMin { InfoRow(label: "Typical error", value: "±\(Format.minutes(mae))") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Order

    private func header(_ order: BarMadeOrder) -> some View {
        VStack(spacing: 6) {
            ViaBarMade()
            Text("THANKS, \((store.name ?? order.customerName ?? "").uppercased())!")
                .font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 8)
            Text(order.displayNumber).font(.system(size: 44, weight: .black)).foregroundStyle(Color.night)
                .accessibilityIdentifier("order-number")
            Text("Sent to \(store.restaurant.name)").foregroundStyle(Color.inkSoft)
            HStack(spacing: 8) {
                if let f = order.fulfillment {
                    Chip(text: (f == "to_go" ? "🥡 To go · packed" : "🍽️ For here · on a plate"), background: .goldTint, foreground: .goldText)
                }
                if let t = order.tableNumber { Chip(text: "Table \(t)", background: .cream, foreground: .ink) }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private func timeline(_ order: BarMadeOrder) -> some View {
        let current = order.stepIndex
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(BarMadeOrder.steps.enumerated()), id: \.offset) { i, step in
                let done = i <= current
                let now = i == current
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle().fill(done ? Color.gold : Color.cream).frame(width: 32, height: 32)
                                .overlay(Circle().stroke(Color.gold.opacity(now && step != "COMPLETED" ? 0.35 : 0), lineWidth: 6))
                            Text(done && !now ? "✓" : "\(i + 1)")
                                .font(.subheadline.weight(.black))
                                .foregroundStyle(done ? Color.night : Color.inkSoft)
                        }
                        if i < BarMadeOrder.steps.count - 1 {
                            Rectangle().fill(i < current ? Color.gold : Color.line).frame(width: 2, height: 36)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(orderStatusTitle(step)).fontWeight(.bold).foregroundStyle(done ? Color.night : Color.inkSoft)
                        if now { Text(stepHint(step, fulfillment: order.fulfillment)).font(.subheadline).foregroundStyle(Color.inkSoft) }
                        if let at = order.time(of: step) { Text(Format.time(at)).font(.caption).foregroundStyle(.tertiary) }
                    }
                    .padding(.top, 5)
                    .accessibilityIdentifier(now ? "step-\(step)" : "")
                }
            }
            if !order.isClosed {
                HStack(spacing: 6) {
                    Circle().fill(Color.fresh).frame(width: 8, height: 8)
                    Text("Live — updates automatically").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private func stepHint(_ step: String, fulfillment: String?) -> String {
        switch step {
        case "RECEIVED": "The kitchen has your order"
        case "PREPARING": "They're cooking it now"
        case "READY": fulfillment == "for_here" ? "Ready! It's on its way to your table" : "Ready! Pick it up at the counter"
        case "COMPLETED": "Enjoy your meal"
        default: ""
        }
    }

    private func items(_ order: BarMadeOrder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your items").font(.headline)
            ForEach(order.items, id: \.menuItemId) { line in
                HStack {
                    Text("\(line.quantity)× \(line.name)")
                    Spacer()
                    Text(Format.money(line.lineTotal)).fontWeight(.semibold).monospacedDigit()
                }
            }
            Divider()
            HStack {
                Text("Total").font(.title3.weight(.black))
                Spacer()
                Text(Format.money(order.total)).font(.title3.weight(.black)).monospacedDigit()
            }
            Text(order.fulfillment == "for_here" ? "Pay at your table." : "Pay when you pick up.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Ticks every second so "Leave in 7:42" stays live between re-plans. The
/// big form is the tracker's headline; `compact` is the one-line form for the
/// cart, the home banner and the orders list, so the timer is never more
/// than a glance away.
struct LeaveCountdown: View {
    let plan: PickupPlan
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = plan.leaveAt.timeIntervalSince(context.date)
            let waiting = plan.shouldWait && remaining > 0
            if compact {
                Text(waiting ? "Leave in \(Self.countdown(remaining))" : "Leave now")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier(waiting ? "leave-countdown-inline" : "leave-now-inline")
            } else {
                VStack(spacing: 8) {
                    if waiting {
                        Text("Leave in").foregroundStyle(.secondary)
                        Text(Self.countdown(remaining))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("leave-countdown")
                        Text("at \(Format.time(plan.leaveAt)) · arrive ~\(Format.time(plan.arriveAt))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Leave now")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(plan.foodWaitMin > PickupPlanner.freshHoldMin ? Color.warn : Color.fresh)
                            .accessibilityIdentifier("leave-now")
                        Text(plan.message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s >= 3600 ? "\(s / 3600)h \((s % 3600) / 60)m" : String(format: "%d:%02d", s / 60, s % 60)
    }
}
