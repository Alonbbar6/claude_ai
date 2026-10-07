import SwiftUI

struct CartView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var raining = false
    @State private var quote: EtaQuote?
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

                    Section("Delivery estimate") {
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
                        if placing { ProgressView().tint(.white) } else { Text("Place order") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(placing)
                    .padding()
                    .background(.bar)
                }
            }
            // Re-quote when the cart or weather changes: both are model features.
            .task(id: "\(store.cartCount)-\(raining)") {
                guard let rid = store.cartRestaurantId else { return }
                quote = try? await store.quote(restaurantId: rid, itemCount: store.cartCount, raining: raining)
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

    private func place() async {
        placing = true
        defer { placing = false }
        do {
            try await store.placeOrder(raining: raining)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
