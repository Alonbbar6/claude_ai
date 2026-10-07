import SwiftUI

struct MenuView: View {
    let restaurant: Restaurant
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    CuisineIcon(cuisine: restaurant.cuisine, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(restaurant.cuisine).foregroundStyle(.secondary)
                        if let quote = store.quotes[restaurant.id] {
                            Text("\(Format.minutes(quote.etaMinutes)) · \(Format.km(quote.route.distanceKm))")
                                .font(.headline)
                            RiskBadge(risk: quote.delayRisk)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Menu") {
                ForEach(restaurant.menu) { item in
                    MenuItemRow(
                        item: item,
                        quantity: store.quantity(of: item.id, in: restaurant.id),
                        onAdd: { store.add(item, from: restaurant.id) },
                        onRemove: { store.remove(item) })
                }
            }
        }
        .navigationTitle(restaurant.name)
        .safeAreaInset(edge: .bottom) {
            if store.cartRestaurantId == restaurant.id && store.cartCount > 0 {
                Button { store.showCart = true } label: {
                    HStack {
                        Text("View cart")
                        Spacer()
                        Text("\(store.cartCount) · \(Format.money(store.cartTotal))")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding()
                .background(.bar)
            }
        }
    }
}

private struct MenuItemRow: View {
    let item: MenuItem
    let quantity: Int
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body.weight(.medium))
                Text(Format.money(item.price)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if quantity > 0 {
                Button(action: onRemove) { Image(systemName: "minus.circle.fill") }
                    .accessibilityLabel("Remove \(item.name)")
                Text("\(quantity)").monospacedDigit().frame(minWidth: 20)
            }
            Button(action: onAdd) { Image(systemName: "plus.circle.fill") }
                .accessibilityLabel("Add \(item.name)")
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
    }
}
