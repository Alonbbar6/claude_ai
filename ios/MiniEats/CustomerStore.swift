import Foundation
import Observation

/// What a customer sees for one dish: the kitchen's menu item plus, when the
/// web app is configured, its photo, description and category.
struct Dish: Identifiable, Hashable {
    enum Availability: Hashable { case available, low(Int), soldOut }

    let item: BarMadeMenuItem
    let servingsLeft: Int
    var description: String?
    var imageURL: URL?
    var category: String = "Menu"
    var allergens: [String] = []
    var vegetarian: Bool?
    var specialReason: String?

    var id: String { item.id }
    var name: String { item.name }
    var price: Double { item.price }
    var isSpecial: Bool { specialReason != nil }

    var availability: Availability {
        if servingsLeft <= 0 { return .soldOut }
        if servingsLeft <= CustomerStore.lowServings { return .low(servingsLeft) }
        return .available
    }
    var orderable: Bool { servingsLeft > 0 }
}

/// Customer-side state against the BarMade API: who's ordering, the live
/// menu and stock, the cart, and the customer's own orders.
@MainActor
@Observable
final class CustomerStore {
    enum Tab: Hashable { case menu, orders, account }

    /// The customer web app shows the kitchen as this restaurant (lib/content.ts).
    static let restaurantName = "Trattoria Little Italy"
    static let restaurantTagline = "Wood-fired pizza and fresh pasta, ready when you are."
    static let restaurantPrepMinutes = 15
    /// "Only n left" at or under this, like the web app's LOW_SERVINGS.
    static let lowServings = 8

    /// BarMade API: BARMADE_API_URL from the project (via Info.plist), else the team's Render host.
    static let defaultServer = infoPlistURL("BarMadeServerURL") ?? "https://barmade-riw5.onrender.com"
    /// Aleska's customer web app, for photos and descriptions. Optional.
    static let defaultWebURL = infoPlistURL("BarMadeWebURL") ?? ""

    private(set) var serverURL: String
    private(set) var webURL: String
    private(set) var name: String?

    // Live menu
    private(set) var menu: [BarMadeMenuItem] = []
    private(set) var inventory: [BarMadeIngredient] = []
    private(set) var web: WebMenu?
    private(set) var loadedAt: Date?
    var loadError: String?
    var isLoading = false

    // Cart: menu item id -> quantity (one kitchen, so no restaurant switching)
    private(set) var cart: [String: Int] = [:]
    var showCart = false

    // My orders, newest first. Ids persist so they survive a relaunch.
    private(set) var orders: [BarMadeOrder] = []
    private(set) var myOrderIds: [String]

    // Navigation
    var selectedTab: Tab = .menu
    var ordersPath: [String] = []

    private let defaults = UserDefaults.standard

    init() {
        serverURL = defaults.string(forKey: "barMadeServerURL") ?? Self.defaultServer
        webURL = defaults.string(forKey: "barMadeWebURL") ?? Self.defaultWebURL
        name = defaults.string(forKey: "customerName")
        myOrderIds = defaults.stringArray(forKey: "myOrderIds") ?? []
        // A server passed as a launch argument (UI tests, installs from a Mac) becomes the default.
        if let i = CommandLine.arguments.firstIndex(of: "-barMadeServerURL"), i + 1 < CommandLine.arguments.count {
            serverURL = CommandLine.arguments[i + 1]
        }
        // UI tests start from the welcome screen every time.
        if CommandLine.arguments.contains("-uiTestReset") {
            for key in ["customerName", "myOrderIds", "barMadeWebURL"] { defaults.removeObject(forKey: key) }
            name = nil
            myOrderIds = []
            webURL = ""
        }
    }

    var client: BarMadeClient {
        BarMadeClient(baseURL: URL(string: serverURL) ?? URL(string: Self.defaultServer)!)
    }

    // MARK: - Session

    func setName(_ newName: String) {
        let trimmed = newName.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        name = String(trimmed.prefix(40))
        defaults.set(name, forKey: "customerName")
    }

    /// Forget the name, cart and order history on this phone.
    func signOut() {
        name = nil
        cart = [:]
        orders = []
        myOrderIds = []
        ordersPath = []
        selectedTab = .menu
        defaults.removeObject(forKey: "customerName")
        defaults.removeObject(forKey: "myOrderIds")
    }

    func updateServerURL(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        serverURL = trimmed.isEmpty ? Self.defaultServer : trimmed
        defaults.set(serverURL, forKey: "barMadeServerURL")
        await load()
    }

    func updateWebURL(_ url: String) async {
        webURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(webURL, forKey: "barMadeWebURL")
        await load()
    }

    // MARK: - Loading

    func start() async { await load() }

    /// Menu and stock from the kitchen; photos and copy from the web app when configured.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let webMenu = fetchWebMenu()
        do {
            async let menu = client.menu()
            async let inventory = client.inventory()
            (self.menu, self.inventory) = try await (menu, inventory)
            loadedAt = Date()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        web = await webMenu
        await refreshOrders()
    }

    private func fetchWebMenu() async -> WebMenu? {
        guard !webURL.isEmpty, let base = URL(string: webURL) else { return nil }
        var request = URLRequest(url: base.appending(path: "/api/menu"))
        request.timeoutInterval = 15
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(WebMenu.self, from: data)
    }

    // MARK: - Dishes

    private func ingredient(_ id: String) -> BarMadeIngredient? { inventory.first { $0.id == id } }

    /// How many of a dish the usable (unexpired) stock can still make. Same
    /// math as the kitchen app and the web menu.
    func servingsLeft(_ item: BarMadeMenuItem) -> Int {
        let counts = item.ingredients.compactMap { line -> Int? in
            guard line.quantity > 0 else { return nil }
            let onHand = ingredient(line.ingredientId)?.totalQuantity ?? 0
            return Int((onHand / line.quantity).rounded(.down))
        }
        return counts.min() ?? 20
    }

    var dishes: [Dish] {
        let webById = Dictionary(uniqueKeysWithValues: (web?.dishes ?? []).map { ($0.id, $0) })
        return menu.map { item in
            var d = Dish(item: item, servingsLeft: servingsLeft(item))
            if let w = webById[item.id] {
                d.description = w.description["en"]
                d.category = w.category
                d.allergens = w.allergens
                d.vegetarian = w.vegetarian
                if let base = URL(string: webURL), let image = w.image { d.imageURL = base.appending(path: image) }
                if web?.special?.dishId == item.id { d.specialReason = web?.special?.reason["en"] }
            } else if let c = item.category, !c.isEmpty {
                d.category = c
            }
            return d
        }
    }

    func dish(_ id: String) -> Dish? { dishes.first { $0.id == id } }

    /// Dishes grouped for the menu: web categories in order, then anything else.
    var sections: [(title: String, dishes: [Dish])] {
        let all = dishes
        let order = web?.categories ?? []
        let known = Set(order)
        var result = order.map { c in (title: WebMenu.categoryLabel(c), dishes: all.filter { $0.category == c }) }
        let other = all.filter { !known.contains($0.category) }
        if !other.isEmpty {
            let rest = Dictionary(grouping: other, by: \.category).sorted { $0.key < $1.key }
            result += rest.map { (title: WebMenu.categoryLabel($0.key), dishes: $0.value) }
        }
        // Available first, sold out last, like the web menu.
        return result.filter { !$0.dishes.isEmpty }.map { s in
            (title: s.title, dishes: s.dishes.sorted { $0.orderable && !$1.orderable })
        }
    }

    // MARK: - Cart

    func quantity(of id: String) -> Int { cart[id] ?? 0 }

    func add(_ dish: Dish, quantity: Int = 1) {
        cart[dish.id] = min(20, (cart[dish.id] ?? 0) + quantity)
    }

    func setQuantity(_ quantity: Int, of id: String) {
        if quantity <= 0 { cart[id] = nil } else { cart[id] = min(20, quantity) }
    }

    var cartLines: [(dish: Dish, quantity: Int)] {
        dishes.compactMap { d in cart[d.id].map { (dish: d, quantity: $0) } }
    }
    var cartCount: Int { cart.values.reduce(0, +) }
    var cartTotal: Double { cartLines.reduce(0) { $0 + $1.dish.price * Double($1.quantity) } }

    // MARK: - Orders

    @discardableResult
    func placeOrder(fulfillment: String, table: String?) async throws -> BarMadeOrder {
        guard let name else { throw APIError(message: "Tell us your name first") }
        guard !cart.isEmpty else { throw APIError(message: "Your order is empty") }
        let body = BarMadeNewOrder(
            items: cartLines.map { .init(menuItemId: $0.dish.id, quantity: $0.quantity) },
            fulfillment: fulfillment,
            tableNumber: fulfillment == "for_here" ? table?.trimmingCharacters(in: .whitespaces).nilIfEmpty : nil,
            customerName: name)
        let order = try await client.placeOrder(body)
        myOrderIds.insert(order.id, at: 0)
        defaults.set(myOrderIds, forKey: "myOrderIds")
        upsert(order)
        cart = [:]
        showCart = false
        selectedTab = .orders
        ordersPath = [order.id]
        // The kitchen just deducted stock; show it.
        Task { await load() }
        return order
    }

    /// The newest order still in the kitchen, for the "Track" banner.
    var activeOrder: BarMadeOrder? { orders.first { $0.isOpen } }

    func order(_ id: String) -> BarMadeOrder? { orders.first { $0.id == id } }

    func refreshOrders() async {
        guard !myOrderIds.isEmpty else { orders = []; return }
        let client = self.client
        let fetched = await withTaskGroup(of: BarMadeOrder?.self) { group in
            for id in myOrderIds { group.addTask { try? await client.order(id) } }
            var out: [BarMadeOrder] = []
            for await o in group { if let o { out.append(o) } }
            return out
        }
        orders = fetched.sorted { $0.createdAt > $1.createdAt }
    }

    func refreshOrder(_ id: String) async {
        if let o = try? await client.order(id) { upsert(o) }
    }

    private func upsert(_ order: BarMadeOrder) {
        if let i = orders.firstIndex(where: { $0.id == order.id }) {
            orders[i] = order
        } else {
            orders.insert(order, at: 0)
            orders.sort { $0.createdAt > $1.createdAt }
        }
    }
}

/// GET /api/menu of the customer web app (customer-web/lib/catalog.ts getMenu).
struct WebMenu: Decodable {
    struct WebDish: Decodable {
        let id: String
        let name: [String: String]
        let description: [String: String]
        let category: String
        let image: String?
        let allergens: [String]
        let vegetarian: Bool?
    }
    struct Special: Decodable {
        let dishId: String
        let reason: [String: String]
    }

    let dishes: [WebDish]
    let categories: [String]
    let special: Special?

    /// Display names from the web app's CATEGORY_LABELS.
    static func categoryLabel(_ c: String) -> String {
        switch c {
        case "Entree": "Mains"
        case "Sandwich": "Sandwiches"
        case "Salad": "Salads"
        case "Appetizer": "Starters"
        case "Dessert": "Desserts"
        case "Beverage": "Drinks"
        default: c
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
