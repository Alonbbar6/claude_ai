import SwiftUI

struct RestaurantListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let error = store.loadError, store.restaurants.isEmpty {
                ContentUnavailableView {
                    Label("Can't reach the server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("\(error)\n\nServer: \(store.serverURL)\nChange it in Account.")
                } actions: {
                    Button("Retry") { Task { await store.start() } }
                        .buttonStyle(.borderedProminent)
                }
            } else if store.restaurants.isEmpty {
                ProgressView("Loading restaurants…")
            } else {
                List(store.restaurants) { restaurant in
                    NavigationLink(value: restaurant) {
                        RestaurantRow(restaurant: restaurant, pickup: store.pickupQuotes[restaurant.id], quote: store.quotes[restaurant.id])
                    }
                }
                .listStyle(.plain)
                .refreshable { await store.loadQuotes() }
                // The first GPS fix usually lands after the list loads: re-quote from here.
                .task(id: store.location.movementKey) {
                    if store.location.coordinate != nil { await store.loadQuotes() }
                }
            }
        }
        .navigationTitle("Order ahead")
        .navigationDestination(for: Restaurant.self) { MenuView(restaurant: $0) }
        .toolbar {
            if store.cartCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.showCart = true } label: {
                        Label("\(store.cartCount)", systemImage: "cart.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
    }
}

private struct RestaurantRow: View {
    @Environment(AppStore.self) private var store
    let restaurant: Restaurant
    let pickup: PickupPlan?
    let quote: EtaQuote?

    var body: some View {
        HStack(spacing: 14) {
            CuisineIcon(cuisine: restaurant.cuisine)
            VStack(alignment: .leading, spacing: 4) {
                Text(restaurant.name).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let pickup {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Ready from ~\(Format.minutes(pickup.readyInMin))").font(.subheadline.bold())
                    Text("\(Format.minutes(pickup.tripMin)) \(pickup.verb)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts = [restaurant.cuisine]
        if let pickup {
            parts.append(store.location.coordinate != nil ? "\(Format.km(pickup.distanceKm)) from you"
                                                            : "\(Format.km(pickup.distanceKm)) from saved address")
        }
        if let a = restaurant.address, !a.isEmpty { parts.append(a) }
        return parts.joined(separator: " · ")
    }
}
