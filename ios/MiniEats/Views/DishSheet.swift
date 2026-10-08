import SwiftUI

/// Dish details with a quantity picker (the web app's DishDetail sheet).
struct DishSheet: View {
    @Environment(CustomerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let dish: Dish
    @State private var quantity = 1

    private var maxQuantity: Int { max(1, min(20, dish.servingsLeft)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if dish.imageURL != nil {
                        DishImage(url: dish.imageURL, size: 0, corner: 20)
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                    }
                    HStack(alignment: .top) {
                        Text(dish.name).font(.title.weight(.black)).foregroundStyle(Color.night)
                        Spacer()
                        Text(Format.money(dish.price)).font(.title3.weight(.black)).foregroundStyle(Color.goldText)
                    }
                    if let d = dish.description, !d.isEmpty {
                        Text(d).foregroundStyle(Color.inkSoft)
                    }

                    FlowChips {
                        if dish.vegetarian == true { Chip(text: "🌱 Vegetarian", background: .freshTint, foreground: .fresh) }
                        switch dish.availability {
                        case .soldOut: Chip(text: "Sold out", background: .night, foreground: .white)
                        case .low(let n): Chip(text: "Only \(n) left", background: .warnTint, foreground: .warn)
                        case .available: EmptyView()
                        }
                        if dish.isSpecial { Chip(text: "★ Chef's special", background: .gold, foreground: .night) }
                    }

                    if let reason = dish.specialReason {
                        (Text("Why today? ").bold() + Text(reason))
                            .font(.subheadline).foregroundStyle(Color.inkSoft)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Made with").font(.subheadline.bold())
                        Text(dish.item.ingredients.map(\.ingredientName).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.inkSoft)
                        if !dish.allergens.isEmpty {
                            Text("Contains: " + dish.allergens.map(\.capitalized).joined(separator: " · "))
                                .font(.subheadline).padding(.top, 4)
                            Text("Based on recipe ingredients. Ask staff about cross-contact.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    QuantityStepper(value: $quantity, range: 1...maxQuantity)
                    Button {
                        store.add(dish, quantity: quantity)
                        dismiss()
                    } label: {
                        Text(dish.orderable ? "Add to order · \(Format.money(dish.price * Double(quantity)))" : "Sold out")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!dish.orderable)
                    .accessibilityIdentifier("add-to-order")
                }
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

/// Wraps chips onto as many lines as needed.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // SwiftUI has no flow layout built in; a horizontal scroll keeps chips from clipping.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) { content }
        }
    }
}
