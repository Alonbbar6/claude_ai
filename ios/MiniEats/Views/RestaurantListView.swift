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
                        RestaurantRow(restaurant: restaurant, quote: store.quotes[restaurant.id])
                    }
                }
                .listStyle(.plain)
                .refreshable { await store.loadQuotes() }
            }
        }
        .navigationTitle("Mini Eats")
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
    let restaurant: Restaurant
    let quote: EtaQuote?

    var body: some View {
        HStack(spacing: 14) {
            CuisineIcon(cuisine: restaurant.cuisine)
            VStack(alignment: .leading, spacing: 4) {
                Text(restaurant.name).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let quote {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Format.minutes(quote.etaMinutes)).font(.subheadline.bold())
                    Circle()
                        .fill(quote.delayRisk >= 0.6 ? .red : quote.delayRisk >= 0.3 ? .orange : .brand)
                        .frame(width: 8, height: 8)
                }
            } else {
                ProgressView()
            }
        }
        .padding(.vertical, 6)
    }

    private var subtitle: String {
        var parts = [restaurant.cuisine]
        if let quote { parts.append(Format.km(quote.route.distanceKm)) }
        return parts.joined(separator: " · ")
    }
}
