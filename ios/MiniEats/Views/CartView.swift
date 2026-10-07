import SwiftUI

struct CartView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var fulfillment: Fulfillment = .delivery
    @State private var mode: TravelMode = .driving
    @State private var raining = false
    @State private var quote: EtaQuote?
    @State private var pickupPlan: PickupPlan?
    @State private var placing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let restaurant = store.cartRestaurant {
                    Section(restaurant.name) {
                        ForEach(store.cartLines) { line in
                            HStack {
                                Text("\(line.quantity)×").foregroundStyle(.secondary).monospacedDigit()
                                Text(line.item.name)
                                Spacer()
                                Text(Format.money(line.item.price * Double(line.quantity)))
                            }
                        }
                    }

                    Section {
                        Picker("Fulfillment", selection: $fulfillment) {
                            Text("Delivery").tag(Fulfillment.delivery)
                            Text("Pickup").tag(Fulfillment.pickup)
                        }
                        .pickerStyle(.segmented)
                        .listRowSeparator(.hidden)

                        if fulfillment == .delivery {
                            deliveryEstimate
                        } else {
                            pickupEstimate
                        }
                    }

                    Section {
                        HStack {
                            Text("Total").font(.headline)
                            Spacer()
                            Text(Format.money(store.cartTotal)).font(.headline)
                        }
                    }
                } else {
                    ContentUnavailableView("Your cart is empty", systemImage: "cart")
                }
            }
            .navigationTitle("Your cart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if store.cartCount > 0 {
                    Button {
                        Task { await place() }
                    } label: {
                        if placing {
                            ProgressView().tint(.white)
                        } else {
                            Text(fulfillment == .pickup ? "Place pickup order" : "Place order")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(placing || pickupPlan?.decision == "too_far" && fulfillment == .pickup)
                    .padding()
                    .background(.bar)
                }
            }
            .onChange(of: fulfillment) { _, new in
                if new == .pickup { store.location.start() }
            }
            // Re-quote whenever a model input changes: cart size, weather,
            // fulfillment, travel mode, or where the customer is.
            .task(id: "\(store.cartCount)-\(raining)-\(fulfillment)-\(mode)-\(store.location.movementKey)") {
                guard let rid = store.cartRestaurantId else { return }
                if fulfillment == .delivery {
                    quote = try? await store.quote(restaurantId: rid, itemCount: store.cartCount, raining: raining)
                } else {
                    pickupPlan = try? await store.pickupQuote(restaurantId: rid, itemCount: store.cartCount, mode: mode)
                }
            }
            .alert("Couldn't place order", isPresented: .init(
                get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    @ViewBuilder private var deliveryEstimate: some View {
        if let quote {
            InfoRow(label: "Arrives in", value: Format.minutes(quote.etaMinutes))
            InfoRow(label: "Distance", value: Format.km(quote.route.distanceKm))
            InfoRow(label: "Drive time",
                    value: "\(Format.minutes(quote.route.durationMin)) · \(quote.route.source == "google" ? "Google Maps" : "estimated")")
            RiskBadge(risk: quote.delayRisk)
        } else {
            ProgressView()
        }
        Toggle("Simulate rain", isOn: $raining)
    }

    @ViewBuilder private var pickupEstimate: some View {
        Picker("Getting there", selection: $mode) {
            ForEach(TravelMode.allCases, id: \.self) { m in
                Label(m.label, systemImage: m.icon).tag(m)
            }
        }
        if let plan = pickupPlan {
            InfoRow(label: "Food ready", value: "~\(Format.time(plan.readyAt))")
            InfoRow(label: "Your trip",
                    value: "\(Format.km(plan.distanceKm)) · \(Format.minutes(plan.tripMin)) \(plan.mode == .driving ? "drive" : "walk")")
            InfoRow(label: "Leave at", value: plan.shouldWait ? Format.time(plan.leaveAt) : "Now")
            Label(plan.message, systemImage: plan.shouldWait ? "clock" : "figure.walk.departure")
                .font(.footnote)
                .foregroundStyle(plan.foodWaitMin > 5 || plan.decision == "too_far" ? .orange : .brand)
        } else {
            ProgressView()
        }
        if store.location.isDenied {
            Text("Location is off, so we're using your saved address.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func place() async {
        placing = true
        defer { placing = false }
        do {
            try await store.placeOrder(raining: raining, fulfillment: fulfillment, mode: mode)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
