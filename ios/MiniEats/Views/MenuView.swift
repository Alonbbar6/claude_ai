import SwiftUI

/// Home + menu in one screen, like the web app's restaurant page: greeting,
/// the active order, the kitchen's card, then dishes by category.
struct MenuView: View {
    @Environment(CustomerStore.self) private var store
    @State private var openDish: Dish?

    var body: some View {
        Group {
            if let error = store.loadError, store.menu.isEmpty {
                ContentUnavailableView {
                    Label("Can't reach the kitchen", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("\(error)\n\nServer: \(store.serverURL)\nChange it in Account.")
                } actions: {
                    Button("Retry") { Task { await store.load() } }.buttonStyle(.borderedProminent)
                }
            } else if store.menu.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waking up the kitchen… the first load can take up to a minute.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            } else {
                menu
            }
        }
        .navigationTitle("Hi, \(store.name ?? "") 👋")
        .toolbar {
            if store.cartCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.showCart = true } label: {
                        Label("\(store.cartCount)", systemImage: "bag.fill").labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("cart-button")
                }
            }
        }
        .sheet(item: $openDish) { DishSheet(dish: $0) }
        .safeAreaInset(edge: .bottom) {
            if store.cartCount > 0 {
                Button { store.showCart = true } label: {
                    HStack {
                        Text("\(store.cartCount)")
                            .font(.subheadline.weight(.black)).foregroundStyle(Color.night)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.gold, in: Capsule())
                        Text("View order").fontWeight(.bold)
                        Spacer()
                        Text(Format.money(store.cartTotal)).fontWeight(.black)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .background(Color.night, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                }
                .padding(.horizontal).padding(.bottom, 6)
                .accessibilityIdentifier("view-order")
            }
        }
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("What are we eating today?").foregroundStyle(.secondary)

                if let active = store.activeOrder {
                    Button {
                        store.selectedTab = .orders
                        store.ordersPath = [active.id]
                    } label: {
                        HStack {
                            Circle().fill(Color.gold).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your order \(active.displayNumber) is \(orderStatusTitle(active.status).lowercased())")
                                    .fontWeight(.semibold)
                                // The leave timer on the home screen, so it's seen without opening the order.
                                if active.status != "READY", let plan = store.plans[active.id] {
                                    LeaveCountdown(plan: plan, compact: true)
                                        .font(.subheadline.weight(.bold)).foregroundStyle(Color.gold)
                                }
                            }
                            Spacer()
                            Text("Track →").fontWeight(.bold).foregroundStyle(Color.gold)
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(Color.night, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .accessibilityIdentifier("active-order")
                }

                restaurantCard

                if !store.arrivalPicks.isEmpty { arrivalPicks }

                ForEach(store.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).font(.title3.weight(.black))
                        ForEach(section.dishes) { dish in
                            DishRow(dish: dish) { openDish = dish }
                        }
                    }
                }

                Text("Classroom demo · synthetic data")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .padding()
        }
        .background(Color.cream)
        .refreshable { await store.load() }
    }

    /// Dishes whose kitchen time fits the trip from where the phone is now:
    /// order one of these and it comes out about as you walk in.
    private var arrivalPicks: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ready when you arrive").font(.title3.weight(.black))
                Spacer()
                if let trip = store.trip {
                    Text("\(Format.minutes(store.tripMinutes(trip.durationMin))) \(store.mode.verb) away")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
            ForEach(store.arrivalPicks) { pick in
                Button { openDish = pick.dish } label: {
                    HStack(spacing: 12) {
                        DishImage(url: pick.dish.imageURL, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pick.dish.name).font(.subheadline.weight(.bold)).foregroundStyle(Color.night)
                            Text("Kitchen ~\(Format.minutes(pick.readyMin)) · \(pick.headline)")
                                .font(.caption).foregroundStyle(Color.inkSoft)
                        }
                        Spacer(minLength: 0)
                        Text(Format.money(pick.dish.price)).font(.subheadline.weight(.black)).foregroundStyle(Color.goldText)
                        ZStack {
                            Circle().fill(Color.gold).frame(width: 32, height: 32)
                            Image(systemName: "plus").font(.subheadline.weight(.black)).foregroundStyle(Color.night)
                        }
                        .onTapGesture { store.add(pick.dish) }
                        .accessibilityLabel("Add \(pick.dish.name)")
                    }
                    .padding(12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pick-\(pick.dish.id)")
            }
            Text("Picked for your distance and the kitchen's pace right now, so the food comes out as you walk in.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var restaurantCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Chip(text: "● Open now", background: .fresh, foreground: .white)
                // From the on-device kitchen model: quickest dish, ordered now, given how busy the kitchen is.
                Chip(text: "⏱ Ready in ~\(Format.minutes(store.menuReadyMinutes))", background: .white, foreground: .night)
            }
            HStack(spacing: 8) {
                Text(store.restaurant.cuisineLine.uppercased()).font(.caption.weight(.black)).foregroundStyle(Color.goldText)
                if store.restaurant.isQA { Chip(text: "QA TEST", background: .warnTint, foreground: .warn) }
            }
            .padding(.top, 6)
            Text(store.restaurant.name).font(.title.weight(.black)).foregroundStyle(Color.night)
            Text(store.restaurant.tagline).foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 4)
    }
}

/// One dish in the menu list. Tap for details and quantity; "+" adds one.
struct DishRow: View {
    @Environment(CustomerStore.self) private var store
    let dish: Dish
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                DishImage(url: dish.imageURL, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(dish.name).font(.body.weight(.bold)).foregroundStyle(Color.night)
                        if dish.isSpecial { Chip(text: "★ Chef's special", background: .gold, foreground: .night) }
                    }
                    if let d = dish.description, !d.isEmpty {
                        Text(d).font(.caption).foregroundStyle(Color.inkSoft).lineLimit(2)
                    } else {
                        Text(dish.item.ingredients.map(\.ingredientName).joined(separator: ", "))
                            .font(.caption).foregroundStyle(Color.inkSoft).lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        Text(Format.money(dish.price)).font(.subheadline.weight(.black)).foregroundStyle(Color.goldText)
                        switch dish.availability {
                        case .soldOut: Chip(text: "Sold out", background: .night, foreground: .white)
                        case .low(let n): Chip(text: "Only \(n) left", background: .warn, foreground: .white)
                        case .available: EmptyView()
                        }
                    }
                }
                Spacer(minLength: 0)
                if dish.orderable {
                    ZStack {
                        Circle().fill(Color.gold).frame(width: 32, height: 32)
                        if store.quantity(of: dish.id) > 0 {
                            Text("\(store.quantity(of: dish.id))").font(.subheadline.weight(.black)).foregroundStyle(Color.night)
                        } else {
                            Image(systemName: "plus").font(.subheadline.weight(.black)).foregroundStyle(Color.night)
                        }
                    }
                    .onTapGesture { store.add(dish) }
                    .accessibilityLabel("Add \(dish.name)")
                    .accessibilityIdentifier("add-\(dish.id)")
                }
            }
            .padding(12)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            .opacity(dish.orderable ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dish-\(dish.id)")
    }
}

/// Photo from the web app when configured, otherwise a warm placeholder.
struct DishImage: View {
    let url: URL?
    var size: CGFloat = 72
    var corner: CGFloat = 12

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    private var placeholder: some View {
        ZStack {
            Color.goldTint
            Image(systemName: "fork.knife").foregroundStyle(Color.gold)
        }
    }
}
