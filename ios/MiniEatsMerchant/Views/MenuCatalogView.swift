import SwiftUI

/// The live menu: categories, items, availability switches and sold-out
/// state driven by inventory.
struct MenuCatalogView: View {
    @Environment(MerchantStore.self) private var store
    @State private var editing: EditTarget?
    @State private var showCategories = false
    @State private var error: String?

    /// `nil` item = creating a new one.
    struct EditTarget: Identifiable {
        let item: MenuItem?
        var id: String { item?.id ?? "new" }
    }

    var body: some View {
        List {
            summary
            ForEach(store.sections, id: \.title) { section in
                Section(section.title) {
                    if section.items.isEmpty {
                        Text("No items").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(section.items) { item in
                        Button { editing = EditTarget(item: item) } label: {
                            CatalogItemRow(item: item, shortages: store.shortages(for: item))
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task {
                                    do { try await store.deleteItem(item.id) } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(store.restaurant?.name ?? "Menu")
        .refreshable { await store.reload() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Categories") { showCategories = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = EditTarget(item: nil) } label: { Label("New item", systemImage: "plus") }
            }
        }
        .sheet(item: $editing) { target in ItemEditorView(item: target.item) }
        .sheet(isPresented: $showCategories) { CategoriesView() }
        .alert("Something went wrong", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var summary: some View {
        let soldOut = store.items.filter { $0.isSoldOut }.count
        let off = store.items.filter { !$0.isAvailable }.count
        return Section {
            HStack(spacing: 10) {
                Stat(value: store.items.count, label: "Items", color: .primary)
                Stat(value: soldOut, label: "Sold out", color: soldOut > 0 ? .red : .secondary)
                Stat(value: off, label: "Turned off", color: off > 0 ? .orange : .secondary)
            }
        }
    }
}

struct Stat: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CatalogItemRow: View {
    let item: MenuItem
    let shortages: [String]
    @Environment(MerchantStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.semibold))
                    if item.isSoldOut {
                        Badge(text: "Sold out", color: .red)
                    } else if !item.isAvailable {
                        Badge(text: "Off", color: .orange)
                    }
                }
                if let d = item.description, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(Format.money(item.price)).font(.subheadline)
                if item.isSoldOut, !shortages.isEmpty {
                    Text("Out of \(shortages.joined(separator: ", ").lowercased())")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Toggle("Available", isOn: Binding(
                get: { item.isAvailable },
                set: { on in Task { await store.setAvailable(item, on) } })
            )
            .labelsHidden()
            .accessibilityLabel("\(item.name) available")
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Item editor

struct ItemEditorView: View {
    let item: MenuItem?
    @Environment(MerchantStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var description = ""
    @State private var price: Double?
    @State private var categoryId: String?
    @State private var available = true
    @State private var recipe: [RecipeEntry] = []
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && (price ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...4)
                    HStack {
                        Text("Price")
                        Spacer()
                        Text("$").foregroundStyle(.secondary)
                        TextField("0.00", value: $price, format: .number.precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                            .accessibilityIdentifier("price-field")
                    }
                    Picker("Category", selection: $categoryId) {
                        Text("No category").tag(String?.none)
                        ForEach(store.categories.sorted { $0.sort < $1.sort }) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                    Toggle("Available to order", isOn: $available)
                }

                Section {
                    ForEach($recipe, id: \.ingredientId) { $entry in
                        if let s = store.stockItem(entry.ingredientId) {
                            HStack {
                                Text(s.name)
                                Spacer()
                                TextField("Qty", value: $entry.quantity, format: .number)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 70)
                                Text(s.unit).foregroundStyle(.secondary).frame(minWidth: 40, alignment: .leading)
                            }
                        }
                    }
                    .onDelete { recipe.remove(atOffsets: $0) }

                    let unused = store.stock.filter { s in !recipe.contains { $0.ingredientId == s.id } }
                    if !unused.isEmpty {
                        Menu {
                            ForEach(unused.sorted { $0.name < $1.name }) { s in
                                Button("\(s.name) (\(s.unit))") {
                                    recipe.append(RecipeEntry(ingredientId: s.id, quantity: 1))
                                }
                            }
                        } label: {
                            // Whole row opens the menu, not just the label text.
                            Label("Add ingredient", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text("Recipe")
                } footer: {
                    Text("Amounts used per item. Orders deduct them from inventory, and the item shows as sold out when any ingredient runs short.")
                }

                if item != nil {
                    Section {
                        Button("Delete item", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .keyboardDoneButton()
            .navigationTitle(item == nil ? "New item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || saving)
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .alert("Couldn't save", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let item else { return }
        name = item.name
        description = item.description ?? ""
        price = item.price
        categoryId = item.categoryId
        available = item.isAvailable
        recipe = item.recipe ?? []
    }

    private func save() async {
        saving = true
        defer { saving = false }
        guard let price else { return }
        let body = ItemBody(
            name: name.trimmingCharacters(in: .whitespaces), price: price,
            description: description.trimmingCharacters(in: .whitespaces),
            categoryId: categoryId, available: available,
            recipe: recipe.filter { $0.quantity > 0 })
        do {
            try await store.saveItem(id: item?.id, body)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() async {
        guard let item else { return }
        do {
            try await store.deleteItem(item.id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Categories

struct CategoriesView: View {
    @Environment(MerchantStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var newName = ""
    @State private var renaming: MenuCategory?
    @State private var renameText = ""
    @State private var showAdd = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.categories.sorted { $0.sort < $1.sort }) { c in
                        Button {
                            renameText = c.name
                            renaming = c
                        } label: {
                            HStack {
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(store.items.filter { $0.categoryId == c.id }.count) items")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in run { try await store.moveCategories(from: from, to: to) } }
                    .onDelete { offsets in
                        let sorted = store.categories.sorted { $0.sort < $1.sort }
                        for i in offsets { run { try await store.deleteCategory(sorted[i].id) } }
                    }
                } footer: {
                    Text("Drag to reorder how customers see the menu. Deleting a category keeps its items under \"No category\".")
                }
            }
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    Button { newName = ""; showAdd = true } label: { Label("Add category", systemImage: "plus") }
                }
            }
            .alert("New category", isPresented: $showAdd) {
                TextField("Name", text: $newName)
                Button("Add") { run { try await store.addCategory(newName) } }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename category", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let c = renaming { run { try await store.renameCategory(c.id, to: renameText) } }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Something went wrong", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        Task {
            do { try await op() } catch { self.error = error.localizedDescription }
        }
    }
}
