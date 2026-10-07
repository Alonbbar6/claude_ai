import SwiftUI

/// Stock levels, problems first, with a stock-out forecast per ingredient.
struct InventoryView: View {
    @Environment(MerchantStore.self) private var store
    @State private var search = ""
    @State private var adding = false

    private var filtered: [StockItem] {
        search.isEmpty ? store.stock : store.stock.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Stat(value: store.stock.filter { $0.status == "out" }.count, label: "Out", color: .red)
                    Stat(value: store.stock.filter { $0.status == "low" }.count, label: "Low", color: .orange)
                    Stat(value: store.stock.filter { $0.status == "ok" }.count, label: "OK", color: .brand)
                }
            }
            Section {
                ForEach(filtered) { item in
                    NavigationLink(value: item.id) { StockRow(item: item) }
                }
            } footer: {
                Text("Forecast uses each ingredient's typical daily usage, or the last hour's order pace when that's faster.")
            }
        }
        .navigationTitle("Inventory")
        .searchable(text: $search)
        .refreshable { await store.reload() }
        .navigationDestination(for: String.self) { IngredientDetailView(ingredientId: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("New ingredient", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) { IngredientEditorView(existing: nil) }
    }
}

private func statusColor(_ status: String) -> Color {
    switch status {
    case "out": .red
    case "low": .orange
    default: .brand
    }
}

private struct StockRow: View {
    let item: StockItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name).font(.body.weight(.semibold))
                if item.status != "ok" {
                    Badge(text: item.status == "out" ? "Out" : "Low", color: statusColor(item.status))
                }
                Spacer()
                Text("\(Format.qty(item.onHand)) \(item.unit)").font(.subheadline.monospacedDigit())
            }
            ProgressView(value: item.fillRatio).tint(statusColor(item.status))
            HStack {
                if item.status == "out" {
                    Text("Out of stock").foregroundStyle(.red)
                } else if let h = item.hoursLeft {
                    Text("Runs out in \(Format.duration(hours: h))")
                }
                Spacer()
                if item.reorderQty > 0 {
                    Text("Reorder \(Format.qty(item.reorderQty)) \(item.unit)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Detail

struct IngredientDetailView: View {
    let ingredientId: String
    @Environment(MerchantStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var history: [StockAdjustment] = []
    @State private var move: String?  // restock | waste | count
    @State private var editing = false
    @State private var confirmDelete = false

    private var item: StockItem? { store.stockItem(ingredientId) }

    var body: some View {
        List {
            if let item {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.qty(item.onHand)).font(.system(size: 40, weight: .bold, design: .rounded))
                                .accessibilityIdentifier("on-hand")
                            Text(item.unit).font(.title3).foregroundStyle(.secondary)
                            Spacer()
                            Badge(text: item.status.uppercased(), color: statusColor(item.status))
                        }
                        ProgressView(value: item.fillRatio).tint(statusColor(item.status))
                        Text("Par \(Format.qty(item.par)) \(item.unit) · alert at \(Format.qty(item.lowThreshold)) \(item.unit)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Forecast") {
                    InfoRow(label: "Usage", value: "\(Format.qty(item.usagePerHour)) \(item.unit)/h")
                    if let h = item.hoursLeft, item.status != "out" {
                        InfoRow(label: "Runs out", value: item.runsOutAt.map { "\(Format.duration(hours: h)) (\(Format.time($0)))" } ?? Format.duration(hours: h))
                    }
                    if let p = item.portionsLeft {
                        InfoRow(label: "Portions left", value: "\(p)")
                    }
                    InfoRow(label: "Suggested reorder", value: item.reorderQty > 0 ? "\(Format.qty(item.reorderQty)) \(item.unit)" : "None")
                    if !item.usedBy.isEmpty {
                        InfoRow(label: "Used in", value: item.usedBy.joined(separator: ", "))
                    }
                }

                Section("Update stock") {
                    Button { move = "restock" } label: { Label("Restock", systemImage: "plus.circle.fill") }
                    Button { move = "count" } label: { Label("Stock count", systemImage: "list.number") }
                    Button { move = "waste" } label: { Label("Record waste", systemImage: "trash") }
                        .tint(.orange)
                }

                Section("History") {
                    if history.isEmpty {
                        Text("No movements yet").foregroundStyle(.secondary)
                    }
                    ForEach(history) { h in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reasonLabel(h.reason)).font(.subheadline)
                                if !h.note.isEmpty { Text(h.note).font(.caption).foregroundStyle(.secondary) }
                                Text(h.at, style: .relative).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text((h.delta >= 0 ? "+" : "") + Format.qty(h.delta))
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(h.delta >= 0 ? Color.brand : .primary)
                                Text("→ \(Format.qty(h.onHandAfter))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button("Edit details") { editing = true }
                    Button("Delete ingredient", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(item?.name ?? "Ingredient")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item?.onHand) { history = await store.history(ingredientId) }
        .sheet(item: Binding(get: { move.map { MoveKind(kind: $0) } }, set: { move = $0?.kind })) { m in
            if let item { StockMoveSheet(item: item, kind: m.kind) }
        }
        .sheet(isPresented: $editing) { if let item { IngredientEditorView(existing: item) } }
        .confirmationDialog("Delete \(item?.name ?? "")?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await store.deleteIngredient(ingredientId)
                    dismiss()
                }
            }
        } message: {
            Text("It will also be removed from every recipe that uses it.")
        }
    }

    private func reasonLabel(_ r: String) -> String {
        switch r {
        case "order": "Customer order"
        case "cancel": "Order cancelled"
        case "restock": "Restock"
        case "waste": "Waste"
        case "count": "Stock count"
        default: r.capitalized
        }
    }
}

private struct MoveKind: Identifiable {
    let kind: String
    var id: String { kind }
}

struct StockMoveSheet: View {
    let item: StockItem
    let kind: String
    @Environment(MerchantStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var quantity: Double = 0
    @State private var note = ""
    @State private var error: String?

    private var title: String {
        switch kind {
        case "restock": "Restock \(item.name)"
        case "waste": "Record waste"
        default: "Stock count"
        }
    }

    private var resulting: Double {
        switch kind {
        case "restock": item.onHand + quantity
        case "waste": max(0, item.onHand - quantity)
        default: quantity
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text(kind == "count" ? "Counted" : "Quantity")
                        Spacer()
                        TextField("0", value: $quantity, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                            .accessibilityIdentifier("quantity-field")
                        Text(item.unit).foregroundStyle(.secondary)
                    }
                    TextField(kind == "restock" ? "Supplier / invoice (optional)" : "Note (optional)", text: $note)
                } footer: {
                    Text("On hand: \(Format.qty(item.onHand)) → \(Format.qty(resulting)) \(item.unit)")
                }
            }
            .keyboardDoneButton()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(kind == "count" ? quantity < 0 : quantity <= 0)
                }
            }
            .alert("Couldn't update stock", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear {
                // Restock defaults to topping up to par; a count starts from the system figure.
                quantity = kind == "restock" ? item.reorderQty : kind == "count" ? item.onHand : 0
            }
        }
        .presentationDetents([.medium])
    }

    private func save() async {
        do {
            try await store.move(item.id, kind: kind, quantity: quantity, note: note)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Create / edit

struct IngredientEditorView: View {
    let existing: StockItem?
    @Environment(MerchantStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var unit = "kg"
    @State private var onHand: Double = 0
    @State private var lowThreshold: Double = 0
    @State private var par: Double = 1
    @State private var dailyUsage: Double = 0
    @State private var error: String?

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !unit.isEmpty && par > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Ingredient") {
                    TextField("Name", text: $name)
                    TextField("Unit (kg, L, each…)", text: $unit).textInputAutocapitalization(.never)
                    if existing == nil { number("Opening stock", $onHand) }
                }
                Section {
                    number("Alert at or below", $lowThreshold)
                    number("Par (restock to)", $par)
                    number("Typical use per day", $dailyUsage)
                } header: {
                    Text("Levels")
                } footer: {
                    Text("Daily use is the forecast baseline; a busier hour of orders takes over automatically.")
                }
            }
            .keyboardDoneButton()
            .navigationTitle(existing == nil ? "New ingredient" : "Edit ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave)
                }
            }
            .alert("Couldn't save", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear {
                guard let e = existing else { return }
                name = e.name; unit = e.unit; lowThreshold = e.lowThreshold; par = e.par; dailyUsage = e.dailyUsage
            }
        }
    }

    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func save() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        do {
            if let e = existing {
                try await store.updateIngredient(e.id, IngredientUpdateBody(
                    name: n, unit: unit, lowThreshold: lowThreshold, par: par, dailyUsage: dailyUsage))
            } else {
                try await store.addIngredient(IngredientBody(
                    name: n, unit: unit, onHand: onHand, lowThreshold: lowThreshold, par: par, dailyUsage: dailyUsage))
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
