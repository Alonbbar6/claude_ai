import SwiftUI

/// Live order status, polled from the kitchen every 3 s like the web order page.
struct OrderTrackerView: View {
    let orderId: String
    @Environment(CustomerStore.self) private var store

    private var order: BarMadeOrder? { store.order(orderId) }

    var body: some View {
        ScrollView {
            if let order {
                VStack(spacing: 16) {
                    header(order)
                    if order.status == "CANCELLED" {
                        Text("Cancelled")
                            .font(.headline).foregroundStyle(Color.warn)
                            .frame(maxWidth: .infinity).padding()
                            .background(Color.warnTint, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("cancelled-header")
                    } else {
                        timeline(order)
                    }
                    items(order)
                }
                .padding()
            } else {
                ProgressView().padding(.top, 80)
            }
        }
        .background(Color.cream)
        .navigationTitle(order.map { "Order \($0.displayNumber)" } ?? "Order")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                await store.refreshOrder(orderId)
                if order?.isClosed ?? false { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func header(_ order: BarMadeOrder) -> some View {
        VStack(spacing: 6) {
            ViaBarMade()
            Text("THANKS, \((store.name ?? order.customerName ?? "").uppercased())!")
                .font(.caption.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 8)
            Text(order.displayNumber).font(.system(size: 44, weight: .black)).foregroundStyle(Color.night)
                .accessibilityIdentifier("order-number")
            Text("Sent to \(CustomerStore.restaurantName)").foregroundStyle(Color.inkSoft)
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
