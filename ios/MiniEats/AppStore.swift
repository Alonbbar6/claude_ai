import Foundation
import Observation
import UserNotifications

/// Single source of app state: catalogue, cart, orders, notifications, and the
/// live WebSocket that streams notifications from the backend.
@MainActor
@Observable
final class AppStore {
    enum Tab: Hashable { case home, orders, notifications, account }

    struct CartLine: Identifiable {
        let item: MenuItem
        let quantity: Int
        var id: String { item.id }
    }

    static let defaultServer = "http://127.0.0.1:8000"

    // Server & session
    private(set) var serverURL: String
    var users: [AppUser] = []
    private(set) var currentUserId: String?
    var isLoading = false
    var loadError: String?
    var socketConnected = false

    // Catalogue
    var restaurants: [Restaurant] = []
    var quotes: [String: EtaQuote] = [:]

    // Cart (single restaurant at a time, like Uber Eats / DoorDash)
    private(set) var cartRestaurantId: String?
    private(set) var cart: [String: Int] = [:]
    var showCart = false

    // Orders & notifications
    var orders: [Order] = []
    var notifications: [AppNotification] = []
    var unreadCount = 0
    var banner: AppNotification?

    // Navigation
    var selectedTab: Tab = .home
    var ordersPath: [String] = []

    private var socketTask: URLSessionWebSocketTask?
    private var socketGeneration = 0

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? Self.defaultServer
        currentUserId = UserDefaults.standard.string(forKey: "userId")
    }

    var api: APIClient {
        APIClient(baseURL: URL(string: serverURL) ?? URL(string: Self.defaultServer)!)
    }

    var currentUser: AppUser? { users.first { $0.id == currentUserId } }
    func restaurant(_ id: String) -> Restaurant? { restaurants.first { $0.id == id } }
    var activeOrderCount: Int { orders.filter { !$0.status.isClosed }.count }

    // MARK: - Loading

    func start() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            users = try await api.get("/api/users")
            restaurants = try await api.get("/api/restaurants")
            if currentUser == nil { setUser(users.first?.id) }
            connectSocket()
            await refreshUserData()
            await loadQuotes()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func updateServerURL(_ url: String) async {
        serverURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverURL, forKey: "serverURL")
        await start()
    }

    func switchUser(_ id: String) async {
        guard id != currentUserId else { return }
        setUser(id)
        orders = []
        notifications = []
        unreadCount = 0
        ordersPath = []
        connectSocket()
        await refreshUserData()
        await loadQuotes()  // distance (and so ETA) depends on who is ordering
    }

    private func setUser(_ id: String?) {
        currentUserId = id
        UserDefaults.standard.set(id, forKey: "userId")
    }

    func refreshUserData() async {
        await refreshOrders()
        await refreshNotifications()
    }

    func refreshOrders() async {
        guard let userId = currentUserId else { return }
        if let fetched: [Order] = try? await api.get("/api/orders", query: ["user_id": userId]) {
            orders = fetched
        }
    }

    func refreshOrder(_ id: String) async {
        guard let order: Order = try? await api.get("/api/orders/\(id)") else { return }
        upsert(order)
    }

    func refreshNotifications() async {
        guard let userId = currentUserId else { return }
        if let fetched: [AppNotification] = try? await api.get("/api/notifications", query: ["user_id": userId]) {
            notifications = fetched
        }
    }

    // MARK: - ETA prediction

    func loadQuotes() async {
        for r in restaurants {
            if let q = try? await quote(restaurantId: r.id, itemCount: 2, raining: false) {
                quotes[r.id] = q
            }
        }
    }

    func quote(restaurantId: String, itemCount: Int, raining: Bool) async throws -> EtaQuote {
        guard let userId = currentUserId else { throw APIError(message: "No user selected") }
        return try await api.post("/api/predict/eta", body: PredictBody(
            userId: userId, restaurantId: restaurantId, itemCount: max(1, itemCount), raining: raining))
    }

    // MARK: - Cart

    func quantity(of itemId: String, in restaurantId: String) -> Int {
        cartRestaurantId == restaurantId ? cart[itemId, default: 0] : 0
    }

    func add(_ item: MenuItem, from restaurantId: String) {
        if cartRestaurantId != restaurantId {
            // Starting a cart at a different restaurant replaces the old one.
            cart = [:]
            cartRestaurantId = restaurantId
        }
        cart[item.id, default: 0] += 1
    }

    func remove(_ item: MenuItem) {
        guard let qty = cart[item.id] else { return }
        cart[item.id] = qty > 1 ? qty - 1 : nil
        if cart.isEmpty { cartRestaurantId = nil }
    }

    var cartRestaurant: Restaurant? { cartRestaurantId.flatMap(restaurant) }
    var cartCount: Int { cart.values.reduce(0, +) }

    var cartLines: [CartLine] {
        guard let r = cartRestaurant else { return [] }
        return r.menu.compactMap { item in
            cart[item.id].map { CartLine(item: item, quantity: $0) }
        }
    }

    var cartTotal: Double {
        cartLines.reduce(0) { $0 + $1.item.price * Double($1.quantity) }
    }

    // MARK: - Orders

    @discardableResult
    func placeOrder(raining: Bool) async throws -> Order {
        guard let userId = currentUserId, let restaurantId = cartRestaurantId else {
            throw APIError(message: "Your cart is empty")
        }
        let body = CreateOrderBody(
            userId: userId,
            restaurantId: restaurantId,
            lines: cartLines.map { OrderLine(itemId: $0.item.id, quantity: $0.quantity) },
            raining: raining)
        let order: Order = try await api.post("/api/orders", body: body)
        // Ask in context, like real delivery apps; iOS only prompts once.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        upsert(order)
        cart = [:]
        cartRestaurantId = nil
        showCart = false
        selectedTab = .orders
        ordersPath = [order.id]
        return order
    }

    /// Demo controls: "advance", "cancel", "refresh-eta" (simulated demand spike).
    func perform(_ action: String, on orderId: String) async {
        let query = action == "refresh-eta" ? ["demand_shock": "4"] : [:]
        if let order: Order = try? await api.post("/api/orders/\(orderId)/\(action)", query: query) {
            upsert(order)
        }
        await refreshNotifications()
    }

    private func upsert(_ order: Order) {
        if let i = orders.firstIndex(where: { $0.id == order.id }) {
            orders[i] = order
        } else {
            orders.insert(order, at: 0)
        }
    }

    // MARK: - Preferences

    func savePreferences(_ prefs: NotificationPrefs) async throws {
        guard let userId = currentUserId else { return }
        let updated: AppUser = try await api.put("/api/users/\(userId)/preferences", body: prefs)
        if let i = users.firstIndex(where: { $0.id == userId }) { users[i] = updated }
    }

    // MARK: - Live notifications (WebSocket)

    func connectSocket() {
        socketTask?.cancel(with: .goingAway, reason: nil)
        socketConnected = false
        guard let userId = currentUserId, var comps = URLComponents(string: serverURL) else { return }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.path = "/ws/\(userId)"
        guard let url = comps.url else { return }

        socketGeneration += 1
        let generation = socketGeneration
        let task = URLSession.shared.webSocketTask(with: url)
        socketTask = task
        task.resume()
        task.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, generation == self.socketGeneration else { return }
                self.socketConnected = error == nil
            }
        }
        Task { await receiveLoop(task, generation: generation) }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation: Int) async {
        while generation == socketGeneration {
            do {
                let message = try await task.receive()
                socketConnected = true
                if case .string(let text) = message { await handleSocket(text) }
            } catch {
                guard generation == socketGeneration else { return }
                socketConnected = false
                try? await Task.sleep(for: .seconds(3))
                if generation == socketGeneration { connectSocket() }  // reconnect
                return
            }
        }
    }

    private func handleSocket(_ text: String) async {
        guard let msg = try? JSONDecoder.api.decode(SocketMessage.self, from: Data(text.utf8)),
              msg.type == "notification" else { return }
        let n = msg.data
        if !notifications.contains(where: { $0.id == n.id }) {
            notifications.insert(n, at: 0)
        }
        if selectedTab != .notifications { unreadCount += 1 }
        banner = n
        postLocalNotification(n)
        if let orderId = n.orderId { await refreshOrder(orderId) }
    }

    /// Mirrors the push into iOS Notification Center. In production this
    /// would be a real APNs push sent by the backend's push channel.
    private func postLocalNotification(_ n: AppNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = n.urgent ? .default : nil
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: n.id, content: content, trigger: nil))
    }
}
