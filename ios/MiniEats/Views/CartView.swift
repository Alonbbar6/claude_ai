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
                            Text(CustomerStore.restaurantName).foregroundStyle(.secondary)
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
        }
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
