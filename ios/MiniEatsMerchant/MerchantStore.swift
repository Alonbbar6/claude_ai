import Foundation
import Observation
import SwiftUI

/// Restaurant-side state: the live menu catalog, inventory and alerts for
/// the selected restaurant.
@MainActor
@Observable
final class MerchantStore {
    /// Built-in server: MINIEATS_SERVER_URL from the project (via Info.plist),
    /// else localhost for the Simulator.
    static let defaultServer: String = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "MiniEatsServerURL") as? String,
           !s.isEmpty, !s.hasPrefix("$(") {
            return s
        }
        return "http://127.0.0.1:8000"
    }()

    /// BarMade kitchen API; picked like a restaurant under `barMadeId`.
    static let barMadeId = "barmade"
    static let defaultBarMadeServer = "https://barmade-riw5.onrender.com"

    private(set) var serverURL: String
    private(set) var barMadeServerURL: String
    private(set) var restaurantId: String?
    var restaurants: [Restaurant] = []
    var categories: [MenuCategory] = []
    var items: [MenuItem] = []
    var stock: [StockItem] = []
    var alerts: [InventoryAlert] = []
    var loadError: String?
    var barMade = BarMadeSnapshot()
    var barMadeError: String?
    private var seenAlertIds: Set<String> = []

    init() {
        serverURL = usableServerURL(saved: UserDefaults.standard.string(forKey: "merchantServerURL"), fallback: Self.defaultServer)
        barMadeServerURL = UserDefaults.standard.string(forKey: "barMadeServerURL") ?? Self.defaultBarMadeServer
        restaurantId = UserDefaults.standard.string(forKey: "merchantRestaurantId")
        // Launch-argument server (set when installed from a Mac) becomes the saved default.
        if CommandLine.arguments.contains("-merchantServerURL") {
            UserDefaults.standard.set(serverURL, forKey: "merchantServerURL")
        }
    }

    var api: APIClient { APIClient(baseURL: URL(string: serverURL) ?? URL(string: Self.defaultServer)!) }
    var restaurant: Restaurant? { restaurants.first { $0.id == restaurantId } }
    var isBarMade: Bool { restaurantId == Self.barMadeId }
    var barMadeClient: BarMadeClient {
        BarMadeClient(baseURL: URL(string: barMadeServerURL) ?? URL(string: Self.defaultBarMadeServer)!)
    }

    private func path(_ p: String) -> String { "/api/merchant/restaurants/\(restaurantId ?? "")\(p)" }

    // MARK: - Loading

    func start() async {
        // BarMade doesn't need the Mini Eats server to be up.
        if isBarMade { await reload() }
        do {
            restaurants = try await api.get("/api/restaurants")
            loadError = nil
            if restaurant == nil && !isBarMade { restaurantId = nil }
            if restaurantId != nil && !isBarMade { await reload() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func select(_ id: String?) async {
        restaurantId = id
        UserDefaults.standard.set(id, forKey: "merchantRestaurantId")
        categories = []; items = []; stock = []; alerts = []; seenAlertIds = []
        barMade = BarMadeSnapshot(); barMadeError = nil
        if id != nil { await reload() }
    }

    func updateServerURL(_ url: String) async {
        serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "merchantServerURL")
        await start()
    }

    func updateBarMadeServerURL(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        barMadeServerURL = trimmed.isEmpty ? Self.defaultBarMadeServer : trimmed
        UserDefaults.standard.set(barMadeServerURL, forKey: "barMadeServerURL")
        await reload()
    }

    func reload() async {
        guard restaurantId != nil else { return }
        if isBarMade { return await reloadBarMade() }
        do {
            let menu: MenuCatalog = try await api.get(path("/menu"))
            categories = menu.categories
            items = menu.items
            stock = try await api.get(path("/inventory"))
            alerts = try await api.get(path("/alerts"))
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func reloadBarMade() async {
        do {
            barMade = try await barMadeClient.snapshot()
            barMadeError = nil
        } catch {
            barMadeError = error.localizedDescription
        }
    }

    /// Moves a BarMade order on, then reloads so every screen shows it.
    /// Returns an error message, or nil on success.
    func setBarMadeOrderStatus(_ orderId: String, to status: String) async -> String? {
        do {
            try await barMadeClient.setStatus(orderId, to: status)
            await reloadBarMade()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func barMadeOrder(_ id: String) -> BarMadeOrder? { barMade.orders.first { $0.id == id } }

    // MARK: - BarMade derived

    func barMadeIngredient(_ id: String) -> BarMadeIngredient? { barMade.inventory.first { $0.id == id } }

    /// How many of a dish the usable (unexpired) stock can still make.
    func portionsLeft(_ item: BarMadeMenuItem) -> Int? {
        item.ingredients.compactMap { line -> Int? in
            guard line.quantity > 0 else { return nil }
            let onHand = barMadeIngredient(line.ingredientId)?.totalQuantity ?? 0
            return Int((onHand / line.quantity).rounded(.down))
        }.min()
    }

    /// Dishes whose recipe uses an ingredient.
    func dishes(using ingredientId: String) -> [String] {
        barMade.menu.filter { $0.ingredients.contains { $0.ingredientId == ingredientId } }.map(\.name)
    }

    var barMadeProblemCount: Int {
        barMade.inventory.filter { $0.level != "ok" || !$0.atRiskBatches.isEmpty }.count
    }
    var barMadeUnreadAlerts: Int {
        barMade.alerts.filter { $0.status == "ACTIVE" && !seenAlertIds.contains($0.id) }.count
    }
    func markBarMadeAlertsSeen() { seenAlertIds.formUnion(barMade.alerts.map(\.id)) }

    // MARK: - Derived

    var sections: [(id: String?, title: String, items: [MenuItem])] {
        let cats = categories.sorted { $0.sort < $1.sort }
        var result: [(id: String?, title: String, items: [MenuItem])] = cats.map { c in
            (c.id, c.name, items.filter { $0.categoryId == c.id })
        }
        let known = Set(cats.map(\.id))
        let other = items.filter { $0.categoryId.map { !known.contains($0) } ?? true }
        if !other.isEmpty { result.append((nil, "No category", other)) }
        return result
    }

    func stockItem(_ id: String) -> StockItem? { stock.first { $0.id == id } }

    /// Why an item is sold out: the ingredients that can't cover one portion.
    func shortages(for item: MenuItem) -> [String] {
        (item.recipe ?? []).compactMap { entry in
            guard let s = stockItem(entry.ingredientId), s.onHand + 1e-9 < entry.quantity else { return nil }
            return s.name
        }
    }

    var problemCount: Int { stock.filter { $0.status != "ok" }.count }
    var unreadAlerts: Int { alerts.filter { !seenAlertIds.contains($0.id) }.count }
    func markAlertsSeen() { seenAlertIds.formUnion(alerts.map(\.id)) }

    // MARK: - Categories

    func addCategory(_ name: String) async throws {
        let _: MenuCategory = try await api.post(path("/categories"), body: NameBody(name: name))
        await reload()
    }

    func renameCategory(_ id: String, to name: String) async throws {
        let _: MenuCategory = try await api.put(path("/categories/\(id)"), body: NameBody(name: name))
        await reload()
    }

    func deleteCategory(_ id: String) async throws {
        try await api.delete(path("/categories/\(id)"))
        await reload()
    }

    func moveCategories(from source: IndexSet, to destination: Int) async throws {
        var ordered = categories.sorted { $0.sort < $1.sort }
        ordered.move(fromOffsets: source, toOffset: destination)
        categories = ordered.enumerated().map { MenuCategory(id: $1.id, name: $1.name, sort: $0) }
        let _: [MenuCategory] = try await api.post(path("/categories/reorder"), body: ReorderBody(ids: ordered.map(\.id)))
        await reload()
    }

    // MARK: - Items

    func saveItem(id: String?, _ body: ItemBody) async throws {
        if let id {
            let _: MenuItem = try await api.put(path("/items/\(id)"), body: body)
        } else {
            let _: MenuItem = try await api.post(path("/items"), body: body)
        }
        await reload()
    }

    func setAvailable(_ item: MenuItem, _ on: Bool) async {
        // Optimistic: flip immediately, then confirm with the server.
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].available = on }
        let _: MenuItem? = try? await api.put(path("/items/\(item.id)"), body: AvailabilityBody(available: on))
        await reload()
    }

    func deleteItem(_ id: String) async throws {
        try await api.delete(path("/items/\(id)"))
        await reload()
    }

    // MARK: - Inventory

    func addIngredient(_ body: IngredientBody) async throws {
        let _: StockItem = try await api.post(path("/inventory"), body: body)
        await reload()
    }

    func updateIngredient(_ id: String, _ body: IngredientUpdateBody) async throws {
        let _: StockItem = try await api.put(path("/inventory/\(id)"), body: body)
        await reload()
    }

    func deleteIngredient(_ id: String) async throws {
        try await api.delete(path("/inventory/\(id)"))
        await reload()
    }

    func move(_ id: String, kind: String, quantity: Double, note: String) async throws {
        let _: StockItem = try await api.post(
            path("/inventory/\(id)/adjust"), body: StockMoveBody(kind: kind, quantity: quantity, note: note))
        await reload()
    }

    func history(_ id: String) async -> [StockAdjustment] {
        (try? await api.get(path("/inventory/\(id)/history"))) ?? []
    }
}
