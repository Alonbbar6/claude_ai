import SwiftUI

/// Merchant view of the BarMade kitchen: batch-level inventory, menu with
/// portions left, orders and expiry alerts. Stock and menu are read-only;
/// the kitchen moves orders through their statuses.
struct BarMadeRootView: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        TabView {
            NavigationStack { BarMadeInventoryView() }
                .tabItem { Label("Inventory", systemImage: "shippingbox.fill") }
                .badge(store.barMadeProblemCount)
            NavigationStack { BarMadeMenuView() }
                .tabItem { Label("Menu", systemImage: "menucard.fill") }
            NavigationStack { BarMadeOrdersView() }
                .tabItem { Label("Orders", systemImage: "receipt.fill") }
                .badge(store.barMade.orders.filter { $0.status == "RECEIVED" }.count)
            NavigationStack { BarMadeAlertsView() }
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(store.barMadeUnreadAlerts)
            NavigationStack { BarMadeSettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.brand)
        .task {
            if store.barMade.updatedAt == nil { await store.reload() }
            while !Task.isCancelled {
                // New tickets should show up while the customer is still at the counter.
                try? await Task.sleep(for: .seconds(10))
                await store.reload()
            }
        }
    }
}

private func levelColor(_ level: String) -> Color {
    switch level {
    case "out": .red
    case "low": .orange
    default: .brand
    }
}

private func batchColor(_ status: String) -> Color {
    switch status {
    case "EXPIRED": .red
    case "EXPIRING_SOON": .orange
    default: .brand
    }
}

private func label(_ status: String) -> String {
    status.replacingOccurrences(of: "_", with: " ").capitalized
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "RECEIVED": .orange
    case "PREPARING": .blue
    case "READY": .purple
    case "CANCELLED": .red
    default: .brand
    }
}

/// Button title for moving an order to `status`.
private func actionTitle(_ status: String) -> String {
    switch status {
    case "PREPARING": "Start preparing"
    case "READY": "Mark ready"
    case "COMPLETED": "Complete"
    case "CANCELLED": "Cancel order"
    default: label(status)
    }
}

private func fulfillmentText(_ order: BarMadeOrder) -> String? {
    switch order.fulfillment {
    case "to_go": "To go"
    case "for_here": order.tableNumber.map { "For here · table \($0)" } ?? "For here"
    default: nil
    }
}

/// Loading spinner while BarMade wakes up, or the last error, above a list.
private struct BarMadeStatus: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        if let error = store.barMadeError {
            Section {
                Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                Button("Try again") { Task { await store.reload() } }
            }
        } else if store.barMade.updatedAt == nil {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to BarMade… the first load can take up to a minute.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Inventory

struct BarMadeInventoryView: View {
    @Environment(MerchantStore.self) private var store
    @State private var search = ""

    private var filtered: [BarMadeIngredient] {
        search.isEmpty ? store.barMade.inventory
            : store.barMade.inventory.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var categories: [String] { Array(Set(filtered.map(\.category))).sorted() }

    var body: some View {
        List {
            BarMadeStatus()
            Section {
                HStack(spacing: 10) {
                    Stat(value: store.barMade.inventory.filter { $0.level == "out" }.count, label: "Out", color: .red)
                    Stat(value: store.barMade.inventory.filter { $0.level == "low" }.count, label: "Low", color: .orange)
                    Stat(value: store.barMade.inventory.filter { !$0.atRiskBatches.isEmpty }.count, label: "Expiring", color: .orange)
                    Stat(value: store.barMade.inventory.filter { $0.level == "ok" }.count, label: "OK", color: .brand)
                }
            }
            ForEach(categories, id: \.self) { category in
                Section(category) {
                    ForEach(filtered.filter { $0.category == category }) { item in
                        NavigationLink(value: item) { BarMadeStockRow(item: item) }
                    }
                }
            }
        }
        .navigationTitle("BarMade Inventory")
        .searchable(text: $search)
        .refreshable { await store.reload() }
        .navigationDestination(for: BarMadeIngredient.self) { BarMadeIngredientView(ingredientId: $0.id) }
    }
}

private struct BarMadeStockRow: View {
    let item: BarMadeIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.body.weight(.semibold))
                if item.level != "ok" {
                    Badge(text: item.level == "out" ? "Out" : "Low", color: levelColor(item.level))
                }
                if let worst = item.atRiskBatches.first(where: { $0.status == "EXPIRED" }) ?? item.atRiskBatches.first {
                    Badge(text: label(worst.status), color: batchColor(worst.status))
                }
                Spacer()
                Text("\(Format.qty(item.totalQuantity)) \(item.unit)").font(.subheadline.monospacedDigit())
            }
            ProgressView(value: item.fillRatio).tint(levelColor(item.level))
            HStack {
                Text("Reorder at \(Format.qty(item.reorderPoint)) \(item.unit)")
                Spacer()
                if item.expiredQuantity > 0 {
                    Text("\(Format.qty(item.expiredQuantity)) \(item.unit) expired").foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct BarMadeIngredientView: View {
    let ingredientId: String
    @Environment(MerchantStore.self) private var store

    private var item: BarMadeIngredient? { store.barMadeIngredient(ingredientId) }

    var body: some View {
        List {
            if let item {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.qty(item.totalQuantity)).font(.system(size: 40, weight: .bold, design: .rounded))
                            Text(item.unit).font(.title3).foregroundStyle(.secondary)
                            Spacer()
                            Badge(text: label(item.status), color: levelColor(item.level))
                        }
                        ProgressView(value: item.fillRatio).tint(levelColor(item.level))
                        Text("Usable stock · reorder at \(Format.qty(item.reorderPoint)) \(item.unit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Details") {
                    InfoRow(label: "Category", value: item.category)
                    InfoRow(label: "Expired", value: "\(Format.qty(item.expiredQuantity)) \(item.unit)")
                    let dishes = store.dishes(using: item.id)
                    if !dishes.isEmpty {
                        InfoRow(label: "Used in", value: dishes.joined(separator: ", "))
                    }
                }

                Section {
                    ForEach(item.batches.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.batchId).font(.subheadline.weight(.semibold))
                                if let e = b.expiresAt {
                                    Text("Expires \(e.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let a = b.arrivedAt {
                                    Text("Arrived \(a.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                Text("\(Format.qty(b.quantity)) \(item.unit)").font(.subheadline.monospacedDigit())
                                Badge(text: label(b.status), color: batchColor(b.status))
                            }
                        }
                    }
                } header: {
                    Text("Batches")
                } footer: {
                    Text("Orders use the batch that expires first. Expired batches aren't used.")
                }
            } else {
                ContentUnavailableView("Ingredient not found", systemImage: "shippingbox")
            }
        }
        .navigationTitle(item?.name ?? "Ingredient")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reload() }
    }
}

// MARK: - Menu

struct BarMadeMenuView: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        List {
            BarMadeStatus()
            Section {
                HStack(spacing: 10) {
                    Stat(value: store.barMade.menu.count, label: "Dishes", color: .primary)
                    let soldOut = store.barMade.menu.filter { (store.portionsLeft($0) ?? 1) == 0 }.count
                    Stat(value: soldOut, label: "Can't make", color: soldOut > 0 ? .red : .secondary)
                }
            }
            Section {
                ForEach(store.barMade.menu) { item in
                    NavigationLink(value: item) { BarMadeDishRow(item: item, portions: store.portionsLeft(item)) }
                }
            } footer: {
                Text("Portions left counts only unexpired stock.")
            }
        }
        .navigationTitle("BarMade Menu")
        .refreshable { await store.reload() }
        .navigationDestination(for: BarMadeMenuItem.self) { BarMadeDishView(item: $0) }
    }
}

private struct BarMadeDishRow: View {
    let item: BarMadeMenuItem
    let portions: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.name).font(.body.weight(.semibold))
                if portions == 0 { Badge(text: "Can't make", color: .red) }
                Spacer()
                Text(Format.money(item.price)).font(.subheadline)
            }
            Text(item.ingredients.map(\.ingredientName).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let portions {
                Text("\(portions) portions left").font(.caption.weight(.medium))
                    .foregroundStyle(portions == 0 ? .red : portions < 10 ? .orange : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct BarMadeDishView: View {
    let item: BarMadeMenuItem
    @Environment(MerchantStore.self) private var store

    var body: some View {
        List {
            Section {
                InfoRow(label: "Price", value: Format.money(item.price))
                if let p = store.portionsLeft(item) { InfoRow(label: "Portions left", value: "\(p)") }
            }
            Section("Recipe (per portion)") {
                ForEach(item.ingredients, id: \.ingredientId) { line in
                    let stock = store.barMadeIngredient(line.ingredientId)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.ingredientName)
                            if let stock {
                                Text("\(Format.qty(stock.totalQuantity)) \(stock.unit) on hand")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(Format.qty(line.quantity)) \(line.unit)").font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Orders

struct BarMadeOrdersView: View {
    @Environment(MerchantStore.self) private var store
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        let open = store.barMade.orders.filter(\.isOpen)
        let done = store.barMade.orders.filter { !$0.isOpen }
        List {
            BarMadeStatus()
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if store.barMade.orders.isEmpty && store.barMade.updatedAt != nil {
                ContentUnavailableView("No orders yet", systemImage: "receipt")
            }
            if !open.isEmpty {
                Section("Open") {
                    ForEach(open) { order in
                        row(order)
                        // The common next step, one tap from the list. Cancel lives on the order page.
                        if let next = order.nextStatuses.first {
                            Button {
                                Task { await advance(order, to: next) }
                            } label: {
                                HStack {
                                    Text(actionTitle(next)).bold()
                                    Spacer()
                                    if busy == order.id { ProgressView() }
                                }
                            }
                            .disabled(busy != nil)
                            .accessibilityIdentifier("advance-\(order.id)")
                        }
                    }
                }
            }
            if !done.isEmpty {
                Section("Done") { ForEach(done) { row($0) } }
            }
        }
        .navigationTitle("BarMade Orders")
        .refreshable { await store.reload() }
        .navigationDestination(for: String.self) { BarMadeOrderView(orderId: $0) }
    }

    private func row(_ order: BarMadeOrder) -> some View {
        NavigationLink(value: order.id) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(order.customerName ?? order.id).font(.body.weight(.semibold))
                    Badge(text: label(order.status), color: statusColor(order.status))
                    Spacer()
                    Text(Format.money(order.total)).font(.subheadline.monospacedDigit())
                }
                Text(order.items.map { "\($0.quantity)× \($0.name)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 6) {
                    if let f = fulfillmentText(order) { Text(f).bold() }
                    Text(order.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if order.customerName != nil { Text("· \(order.id)") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func advance(_ order: BarMadeOrder, to status: String) async {
        busy = order.id
        error = await store.setBarMadeOrderStatus(order.id, to: status)
        busy = nil
    }
}

struct BarMadeOrderView: View {
    @Environment(MerchantStore.self) private var store
    let orderId: String
    @State private var busy = false
    @State private var error: String?
    @State private var confirmCancel = false

    var body: some View {
        // Read from the store so a status change (here or by refresh) shows at once.
        if let order = store.barMadeOrder(orderId) {
            content(order)
        } else {
            ContentUnavailableView("Order not found", systemImage: "receipt")
        }
    }

    private func content(_ order: BarMadeOrder) -> some View {
        List {
            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Badge(text: label(order.status), color: statusColor(order.status))
                }
                if let name = order.customerName { InfoRow(label: "Customer", value: name) }
                if let f = fulfillmentText(order) { InfoRow(label: "Fulfillment", value: f) }
                InfoRow(label: "Placed", value: order.createdAt.formatted(date: .abbreviated, time: .shortened))
                if order.customerName != nil { InfoRow(label: "Order", value: order.id) }
            }
            if order.isOpen {
                Section {
                    ForEach(order.nextStatuses.filter { $0 != "CANCELLED" }, id: \.self) { next in
                        Button(actionTitle(next)) { Task { await advance(order, to: next) } }
                            .bold()
                    }
                    if order.nextStatuses.contains("CANCELLED") {
                        Button("Cancel order", role: .destructive) { confirmCancel = true }
                    }
                    if busy { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                } footer: {
                    Text("The customer's order page updates within a few seconds.")
                }
                .disabled(busy)
            }
            Section("Items") {
                ForEach(order.items, id: \.menuItemId) { line in
                    HStack {
                        Text("\(line.quantity)× \(line.name)")
                        Spacer()
                        Text(Format.money(line.lineTotal)).monospacedDigit()
                    }
                }
                HStack {
                    Text("Total").bold()
                    Spacer()
                    Text(Format.money(order.total)).bold().monospacedDigit()
                }
            }
            if let history = order.statusHistory, !history.isEmpty {
                Section("Timeline") {
                    ForEach(history, id: \.self) { h in
                        HStack {
                            Text(label(h.status))
                            Spacer()
                            Text(h.at.formatted(date: .omitted, time: .shortened))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            Section("Stock used") {
                ForEach(order.consumed, id: \.ingredientId) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.ingredientName)
                            Text(c.batches.map(\.batchId).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Format.qty(c.quantity)) \(c.unit)").font(.subheadline.monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle(order.customerName ?? order.id)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Cancel this order?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel order", role: .destructive) { Task { await advance(order, to: "CANCELLED") } }
            Button("Keep order", role: .cancel) {}
        } message: {
            Text("The customer will see it as cancelled.")
        }
    }

    private func advance(_ order: BarMadeOrder, to status: String) async {
        busy = true
        error = await store.setBarMadeOrderStatus(order.id, to: status)
        busy = false
    }
}

// MARK: - Alerts

struct BarMadeAlertsView: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        List {
            BarMadeStatus()
            if store.barMade.alerts.isEmpty && store.barMade.updatedAt != nil {
                ContentUnavailableView(
                    "No alerts", systemImage: "checkmark.seal",
                    description: Text("Expired and expiring batches show up here."))
            }
            ForEach(store.barMade.alerts) { alert in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: alert.type == "EXPIRED" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(alert.type == "EXPIRED" ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.message).font(.subheadline)
                        HStack(spacing: 6) {
                            if let batch = alert.batchId { Text(batch) }
                            if let q = alert.quantity, let u = alert.unit { Text("· \(Format.qty(q)) \(u)") }
                            if let e = alert.expiresAt {
                                Text("· expires \(e.formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(alert.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if alert.status != "ACTIVE" { Badge(text: label(alert.status), color: .secondary) }
                }
            }
        }
        .navigationTitle("BarMade Alerts")
        .refreshable { await store.reload() }
        .onAppear { store.markBarMadeAlertsSeen() }
        .onChange(of: store.barMade.alerts) { store.markBarMadeAlertsSeen() }
    }
}

// MARK: - Settings

struct BarMadeSettingsView: View {
    @Environment(MerchantStore.self) private var store
    @State private var server = ""

    var body: some View {
        Form {
            Section("Kitchen") {
                InfoRow(label: "Source", value: "BarMade API")
                if let at = store.barMade.updatedAt {
                    InfoRow(label: "Last updated", value: Format.time(at))
                }
                Button("Refresh now") { Task { await store.reload() } }
                Button("Switch restaurant") { Task { await store.select(nil) } }
            }
            Section {
                TextField(MerchantStore.defaultBarMadeServer, text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") { Task { await store.updateBarMadeServerURL(server) } }
                if let error = store.barMadeError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("BarMade server")
            } footer: {
                Text("Stock and menu are managed in BarMade. Orders can be moved through their statuses here.")
            }
        }
        .navigationTitle("Settings")
        .onAppear { server = store.barMadeServerURL }
    }
}
