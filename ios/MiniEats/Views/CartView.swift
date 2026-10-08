import SwiftUI

/// Review the order, choose to go / for here, and send it to the kitchen.
struct CartView: View {
    @Environment(CustomerStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var fulfillment = "to_go"
    @State private var table = ""
    @State private var placing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.cartLines.isEmpty {
                    ContentUnavailableView("Your order is empty", systemImage: "bag")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(store.restaurant.name).foregroundStyle(.secondary)
                            VStack(spacing: 12) {
                                ForEach(store.cartLines, id: \.dish.id) { line in
                                    HStack(spacing: 12) {
                                        DishImage(url: line.dish.imageURL, size: 56)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(line.dish.name).fontWeight(.bold).foregroundStyle(Color.night)
                                            Text(Format.money(line.dish.price * Double(line.quantity)))
                                                .font(.subheadline.bold()).foregroundStyle(Color.goldText)
                                        }
                                        Spacer()
                                        QuantityStepper(
                                            value: Binding(
                                                get: { line.quantity },
                                                set: { store.setQuantity($0, of: line.dish.id) }),
                                            range: 0...max(1, min(20, line.dish.servingsLeft)))
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("How do you want it?").font(.headline)
                                HStack(spacing: 12) {
                                    fulfillmentCard("to_go", icon: "🥡", title: "To go", hint: "Packed to take away")
                                    fulfillmentCard("for_here", icon: "🍽️", title: "For here", hint: "Served on a plate")
                                }
                                if fulfillment == "for_here" {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Table number (optional)").font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkSoft)
                                        TextField("", text: $table)
                                            .keyboardType(.numbersAndPunctuation)
                                            .onChange(of: table) { _, v in
                                                table = String(v.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(8))
                                            }
                                            .padding(12)
                                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                                            .accessibilityIdentifier("table-field")
                                    }
                                }
                            }

                            pickupTiming

                            Divider()
                            HStack {
                                Text("Total").font(.title3.weight(.black))
                                Spacer()
                                Text(Format.money(store.cartTotal)).font(.title3.weight(.black))
                            }
                            Text(fulfillment == "to_go" ? "Pay when you pick up." : "Pay at your table.")
                                .font(.subheadline).foregroundStyle(Color.inkSoft)

                            if let error {
                                Text(error)
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.warn)
                                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.warnTint, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityIdentifier("order-error")
                            }
                        }
                        .padding()
                    }
                    .background(Color.cream)
                    .safeAreaInset(edge: .bottom) {
                        Button {
                            Task { await place() }
                        } label: {
                            if placing {
                                HStack(spacing: 8) { ProgressView().tint(.night); Text("Sending to the kitchen…") }
                            } else {
                                Text("Place order · \(Format.money(store.cartTotal))")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(placing)
                        .padding()
                        .background(.bar)
                        .accessibilityIdentifier("place-order")
                    }
                }
            }
            .navigationTitle("Your order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear {
                store.location.start()
                store.suggestMode()
                Task { await store.quoteCart() }
            }
            // Re-quote when the customer moves.
            .task(id: store.location.movementKey) { await store.quoteCart() }
        }
    }

    /// When the food will be ready and when to leave, from the on-device model
    /// and the phone's location (the old app asked the server for this).
    @ViewBuilder private var pickupTiming: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(fulfillment == "to_go" ? "Pickup timing" : "Kitchen timing").font(.headline)
                Spacer()
                if fulfillment == "to_go" {
                    Picker("Getting there", selection: Binding(
                        get: { store.mode }, set: { m in Task { await store.setMode(m) } })
                    ) {
                        ForEach(TravelMode.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
            if let ready = store.cartReady {
                InfoRow(label: "Food ready", value: "~\(Format.minutes(ready.p50)) (by \(Format.minutes(ready.p90)))")
            }
            if fulfillment == "to_go" {
                if let plan = store.quote {
                    InfoRow(label: "Your trip", value: "\(Format.km(plan.distanceKm)) · \(Format.minutes(plan.tripMin)) \(plan.verb)")
                    // A live timer, not a clock time: it keeps counting while the cart is open.
                    HStack {
                        Text("Leave").foregroundStyle(.secondary)
                        Spacer()
                        LeaveCountdown(plan: plan, compact: true).fontWeight(.semibold)
                        if plan.shouldWait {
                            Text("(at \(Format.time(plan.leaveAt)))").foregroundStyle(.secondary)
                        }
                    }
                    Label(plan.message, systemImage: plan.shouldWait ? "clock" : "figure.walk.departure")
                        .font(.footnote)
                        .foregroundStyle(plan.foodWaitMin > PickupPlanner.freshHoldMin || plan.tooFar ? Color.warn : Color.fresh)
                } else if store.location.isDenied {
                    Text("Turn on location in Settings to see when to leave.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Finding your location to plan when to leave…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("pickup-timing")
    }

    private func fulfillmentCard(_ value: String, icon: String, title: String, hint: String) -> some View {
        let selected = fulfillment == value
        return Button { fulfillment = value } label: {
            VStack(spacing: 4) {
                Text(icon).font(.largeTitle)
                Text(title).font(.headline).foregroundStyle(Color.night)
                Text(hint).font(.caption).foregroundStyle(Color.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(selected ? Color.goldTint : Color.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.gold : Color.line, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fulfillment-\(value)")
    }

    private func place() async {
        placing = true
        error = nil
        defer { placing = false }
        do {
            try await store.placeOrder(fulfillment: fulfillment, table: table)
            dismiss()
        } catch let e as APIError where e.status == 409 {
            // The kitchen's stock changed under us; the menu refreshes with "Sold out".
            error = "Sorry, some items just sold out: \(e.message)"
            await store.load()
        } catch {
            self.error = "We couldn't place your order. \(error.localizedDescription)"
        }
    }
}
