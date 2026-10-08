import SwiftUI

/// Purchasing: who the kitchen buys from, what they charge, what has been
/// ordered, and what's in the cart. Managed in the BarMade manager dashboard;
/// the phone reads it so the owner can check a vendor or an order on the go.
struct BarMadeVendorsView: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        List {
            if let error = store.purchasingError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                    Button("Try again") { Task { await store.reloadPurchasing() } }
                }
            } else if store.purchasing.updatedAt == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading vendors…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack(spacing: 10) {
                    Stat(value: store.purchasing.vendors.count, label: "Vendors", color: .primary)
                    Stat(value: store.openPurchaseOrders, label: "Open orders", color: store.openPurchaseOrders > 0 ? .orange : .secondary)
                    Stat(value: store.purchasing.cart.count, label: "In cart", color: store.purchasing.cart.count > 0 ? .brand : .secondary)
                }
            }

            Section("Vendors") {
                if store.purchasing.vendors.isEmpty && store.purchasing.updatedAt != nil {
                    Text("No vendors yet — add one in the manager dashboard.").foregroundStyle(.secondary)
                }
                ForEach(store.purchasing.vendors) { vendor in
                    NavigationLink(value: Route.vendor(vendor.id)) { VendorRow(vendor: vendor) }
                }
            }

            Section {
                if store.purchasing.purchaseOrders.isEmpty && store.purchasing.updatedAt != nil {
                    Text("No purchase orders yet.").foregroundStyle(.secondary)
                }
                ForEach(store.purchasing.purchaseOrders) { order in
                    NavigationLink(value: Route.purchaseOrder(order.id)) { PurchaseOrderRow(order: order) }
                }
            } header: {
                Text("Purchase orders")
            }

            Section {
                if store.purchasing.cart.items.isEmpty {
                    Text("Cart is empty.").foregroundStyle(.secondary)
                }
                ForEach(store.purchasing.cart.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.ingredientName)
                            if let label = item.packLabel {
                                Text(label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(Format.qty(item.quantity)) \(item.unit)").font(.subheadline.monospacedDigit())
                        Badge(text: item.status.capitalized, color: item.status == "ordered" ? .brand : .orange)
                    }
                }
            } header: {
                Text("Shopping cart")
            } footer: {
                Text("Vendors, prices and orders are managed in the BarMade manager dashboard. This screen is read-only.")
            }
        }
        .navigationTitle("Vendors")
        .refreshable { await store.reloadPurchasing() }
        .navigationDestination(for: Route.self) { route in
            switch route {
            case .vendor(let id): BarMadeVendorView(vendorId: id)
            case .purchaseOrder(let id): BarMadePurchaseOrderView(orderId: id)
            }
        }
    }

    enum Route: Hashable {
        case vendor(String)
        case purchaseOrder(String)
    }
}

private func relationshipColor(_ relationship: String) -> Color {
    switch relationship {
    case "local": .brand
    case "corporate": .purple
    default: .blue
    }
}

private func poStatusColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "received": .brand
    case "cancelled": .red
    case "draft": .secondary
    default: .orange
    }
}

private struct VendorRow: View {
    let vendor: BarMadeVendor
    @Environment(MerchantStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(vendor.name).font(.body.weight(.semibold))
                Badge(text: vendor.relationshipLabel, color: relationshipColor(vendor.relationship))
                Spacer()
                let spend = store.purchasing.spend(with: vendor.id)
                if spend > 0 { Text(Format.money(spend)).font(.subheadline.monospacedDigit()) }
            }
            Text(vendor.email).font(.caption).foregroundStyle(.secondary)
            Text("\(vendor.productTotal) products priced · \(store.purchasing.orders(for: vendor.id).count) orders")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct PurchaseOrderRow: View {
    let order: BarMadePurchaseOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(order.title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(Format.money(order.total)).font(.subheadline.monospacedDigit())
            }
            HStack(spacing: 6) {
                Badge(text: order.status.capitalized, color: poStatusColor(order.status))
                Text(order.vendorName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Format.dateTime(order.receivedAt ?? order.createdAt)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Vendor

struct BarMadeVendorView: View {
    let vendorId: String
    @Environment(MerchantStore.self) private var store

    private var vendor: BarMadeVendor? { store.vendor(vendorId) }

    var body: some View {
        List {
            if let vendor {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "storefront.fill")
                            .font(.title2).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(relationshipColor(vendor.relationship), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vendor.name).font(.headline)
                            Badge(text: "\(vendor.relationshipLabel) vendor", color: relationshipColor(vendor.relationship))
                            if let notes = vendor.notes, !notes.isEmpty {
                                Text(notes).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if !vendor.email.isEmpty, let url = URL(string: "mailto:\(vendor.email)") {
                        Link(destination: url) { Label(vendor.email, systemImage: "envelope") }
                    }
                    if let phone = vendor.phone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                        Link(destination: url) { Label(phone, systemImage: "phone") }
                    }
                    if let at = vendor.createdAt {
                        InfoRow(label: "Added", value: at.formatted(date: .abbreviated, time: .omitted))
                    }
                }

                Section {
                    if vendor.products.isEmpty {
                        Text("No products priced for this vendor yet.").foregroundStyle(.secondary)
                    }
                    let products = vendor.products.sorted { $0.ingredientName < $1.ingredientName }
                    ForEach(products) { product in
                        VendorProductRow(product: product, stock: store.barMadeIngredient(product.ingredientId))
                    }
                } header: {
                    Text("Products & prices")
                }

                Section("Purchase orders") {
                    let orders = store.purchasing.orders(for: vendor.id)
                    if orders.isEmpty {
                        Text("Nothing ordered from this vendor yet.").foregroundStyle(.secondary)
                    }
                    ForEach(orders) { order in
                        NavigationLink(value: BarMadeVendorsView.Route.purchaseOrder(order.id)) { PurchaseOrderRow(order: order) }
                    }
                    if !orders.isEmpty {
                        InfoRow(label: "Total spend", value: Format.money(store.purchasing.spend(with: vendor.id)))
                    }
                }
            } else {
                ContentUnavailableView("Vendor not found", systemImage: "storefront")
            }
        }
        .navigationTitle(vendor?.name ?? "Vendor")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reloadPurchasing() }
    }
}

private struct VendorProductRow: View {
    let product: BarMadeVendorProduct
    let stock: BarMadeIngredient?

    private var detail: String {
        var parts: [String] = []
        if let label = product.packLabel { parts.append(label) }
        if let stock { parts.append("\(Format.qty(stock.totalQuantity)) \(stock.unit) on hand") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(product.ingredientName)
                if !detail.isEmpty {
                    Text(detail).font(.caption)
                        .foregroundStyle(stock.map { $0.level == "ok" } ?? true ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            Text("\(Format.money(product.pricePerPack))/pack").font(.subheadline.monospacedDigit())
        }
    }
}

// MARK: - Purchase order

struct BarMadePurchaseOrderView: View {
    let orderId: String
    @Environment(MerchantStore.self) private var store

    private var order: BarMadePurchaseOrder? { store.purchaseOrder(orderId) }

    var body: some View {
        List {
            if let order {
                Section {
                    HStack {
                        Text(Format.money(order.total)).font(.system(size: 34, weight: .bold, design: .rounded))
                        Spacer()
                        Badge(text: order.status.capitalized, color: poStatusColor(order.status))
                    }
                    .padding(.vertical, 4)
                    InfoRow(label: "Vendor", value: order.vendorName)
                    InfoRow(label: "Sent", value: Format.dateTime(order.createdAt))
                    if let at = order.receivedAt {
                        InfoRow(label: "Received", value: Format.dateTime(at))
                    }
                }

                Section("Items") {
                    ForEach(order.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.ingredientName)
                                Text("\(Format.qty(item.packs)) packs × \(Format.qty(item.packSize)) \(item.unit) = \(Format.qty(item.units)) \(item.unit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Format.money(item.lineTotal)).font(.subheadline.monospacedDigit())
                                Text("\(Format.money(item.pricePerPack))/pack").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let body = order.emailBody, !body.isEmpty {
                    Section {
                        if let subject = order.emailSubject { InfoRow(label: "Subject", value: subject) }
                        if let to = order.emailTo { InfoRow(label: "To", value: to) }
                        Text(body).font(.callout).textSelection(.enabled)
                    } header: {
                        Text("Order email")
                    } footer: {
                        Text("Written by the manager dashboard in the vendor's tone; the numbers come from the cart.")
                    }
                }
            } else {
                ContentUnavailableView("Order not found", systemImage: "doc.text")
            }
        }
        .navigationTitle(order?.title ?? "Purchase order")
        .navigationBarTitleDisplayMode(.inline)
    }
}
