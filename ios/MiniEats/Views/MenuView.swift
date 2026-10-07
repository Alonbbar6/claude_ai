import SwiftUI

struct MenuView: View {
    let restaurant: Restaurant
    @Environment(AppStore.self) private var store

    /// The latest copy from the store (menu edits, sold-out flags).
    private var currentRestaurant: Restaurant { store.restaurant(restaurant.id) ?? restaurant }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    CuisineIcon(cuisine: restaurant.cuisine, size: 64)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(restaurant.cuisine).foregroundStyle(.secondary)
                        if let a = restaurant.address, !a.isEmpty {
                            Label(a, systemImage: "mappin.and.ellipse").font(.subheadline)
                        }
                        if let p = store.pickupQuotes[restaurant.id] {
                            Text("Pickup: ready from ~\(Format.minutes(p.readyInMin)) · \(Format.minutes(p.tripMin)) \(p.verb)")
                                .font(.headline)
                            Text("\(Format.km(p.distanceKm)) from you").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            ForEach(currentRestaurant.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        MenuItemRow(
                            item: item,
                            quantity: store.quantity(of: item.id, in: restaurant.id),
                            onAdd: { store.add(item, from: restaurant.id) },
                            onRemove: { store.remove(item) })
                    }
                }
            }
        }
        .navigationTitle(restaurant.name)
        // Pick up menu edits and sell-outs from the restaurant side.
        .refreshable { await store.refreshRestaurants() }
        .task { await store.refreshRestaurants() }
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
                if let d = item.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(Format.money(item.price)).font(.subheadline).foregroundStyle(.secondary)
                    if let p = item.prepMin, p <= 3 {
                        Text("ready in ~\(Int(p.rounded())) min")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.brand.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.brand)
                    }
                }
            }
            .opacity(item.orderable ? 1 : 0.45)
            Spacer()
            if !item.orderable {
                Text(item.isSoldOut ? "Sold out" : "Unavailable")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .foregroundStyle(.secondary)
            } else if quantity > 0 {
                Button(action: onRemove) { Image(systemName: "minus.circle.fill") }
                    .accessibilityLabel("Remove \(item.name)")
                Text("\(quantity)").monospacedDigit().frame(minWidth: 20)
            }
            if item.orderable {
                Button(action: onAdd) { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel("Add \(item.name)")
            }
        }
        .font(.title3)
        .buttonStyle(.borderless)
        .foregroundStyle(Color.primary)
    }
}
