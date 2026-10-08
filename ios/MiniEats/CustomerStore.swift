import CoreLocation
import Foundation
import MapKit
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
    /// Kitchen minutes this dish needs (prior; the model scales it).
    var prepMin: Double { ReadyTimeModel.prepPrior(for: item) }

    var availability: Availability {
        if servingsLeft <= 0 { return .soldOut }
        if servingsLeft <= CustomerStore.lowServings { return .low(servingsLeft) }
        return .available
    }
    var orderable: Bool { servingsLeft > 0 }
}

/// Customer-side state against the BarMade API: who's ordering, the live
/// menu and stock, the cart, the customer's own orders, and the pickup
/// planning (ready-time model + routing + leave-time reminders) that runs
/// on the phone.
@MainActor
@Observable
final class CustomerStore {
    enum Tab: Hashable { case menu, map, orders, account }

    /// BarMade publishes no restaurant profile, so the app carries the places the
    /// kitchen can be demoed as. All of them order from the same kitchen API.
    static let restaurants: [RestaurantProfile] = [
        RestaurantProfile(
            id: "trattoria-little-italy", name: "Trattoria Little Italy", cuisineLine: "Italian · Little Italy",
            tagline: "Wood-fired pizza and fresh pasta, ready when you are.",
            address: "120 E Flagler St, Miami, FL 33131",
            coordinate: CLLocationCoordinate2D(latitude: 25.7743, longitude: -80.1925), isQA: false),
        RestaurantProfile(
            id: "qa-mdc-wolfson", name: "QA Test Kitchen · MDC Wolfson", cuisineLine: "Italian · Downtown Miami",
            tagline: "Test orders for the demo at Miami Dade College, Wolfson Campus.",
            address: "300 NE 2nd Ave, Miami, FL 33132",
            coordinate: CLLocationCoordinate2D(latitude: 25.7778, longitude: -80.1894), isQA: true),
    ]
    /// Later than this past the quote counts as "running late" (same as the old server).
    static let delayAlertMin = 5.0
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

    // The kitchen as a whole: every ticket, for how busy it is and for the model.
    private(set) var kitchenOrders: [BarMadeOrder] = []
    private(set) var model = ReadyTimeModel()

    // Cart: menu item id -> quantity (one kitchen, so no restaurant switching)
    private(set) var cart: [String: Int] = [:]
    var showCart = false
    /// Pickup plan for the cart, from where the phone is now. nil without a fix.
    private(set) var quote: PickupPlan?
    /// Kitchen estimate for the cart, available even without a location.
    private(set) var cartReady: ReadyEstimate?

    // My orders, newest first. Ids persist so they survive a relaunch.
    private(set) var orders: [BarMadeOrder] = []
    private(set) var myOrderIds: [String]
    /// Leave-time plan per open order, re-planned as the phone moves.
    private(set) var plans: [String: PickupPlan] = [:]
    /// Routed path to the restaurant per order, for the map.
    private(set) var routes: [String: MKPolyline] = [:]

    // Pickup trip
    let location = LocationService()
    private(set) var restaurant: RestaurantProfile
    private(set) var restaurantAddress: String
    private(set) var restaurantCoordinate: CLLocationCoordinate2D
    /// What the app promised at checkout, so it can say "running late" honestly.
    private(set) var quotedReady: [String: Date] = [:]
    @ObservationIgnored private var lastToldReady: [String: Date] = [:]
    var mode: TravelMode {
        didSet { defaults.set(mode.rawValue, forKey: "travelMode") }
    }
    /// Minutes from "arrived" to "at the counter" (parking, walking in), per travel
    /// mode. Adjustable under Account → Pickup timing; the planner's defaults otherwise.
    private(set) var arrivalOverhead: [TravelMode: Double]
    /// Your trip to the restaurant from where the phone is now (the Map tab); nil without a fix.
    private(set) var trip: RouteEstimate?
    private(set) var tripLine: MKPolyline?

    // Navigation
    var selectedTab: Tab = .menu
    var ordersPath: [String] = []

    private let defaults = UserDefaults.standard
    @ObservationIgnored private var lastReplan = Date.distantPast
    @ObservationIgnored private var knownStatuses: [String: String] = [:]

    init() {
        serverURL = defaults.string(forKey: "barMadeServerURL") ?? Self.defaultServer
        webURL = defaults.string(forKey: "barMadeWebURL") ?? Self.defaultWebURL
        name = defaults.string(forKey: "customerName")
        myOrderIds = defaults.stringArray(forKey: "myOrderIds") ?? []
        let savedRestaurant = UserDefaults.standard.string(forKey: "restaurantId")
        let profile = Self.restaurants.first { $0.id == savedRestaurant } ?? Self.restaurants[0]
        restaurant = profile
        restaurantAddress = defaults.string(forKey: "restaurantAddress.\(profile.id)") ?? profile.address
        restaurantCoordinate = profile.coordinate
        quotedReady = (defaults.dictionary(forKey: "quotedReady") as? [String: Double] ?? [:])
            .mapValues { Date(timeIntervalSince1970: $0) }
        mode = TravelMode(rawValue: defaults.string(forKey: "travelMode") ?? "") ?? .driving
        let saved = UserDefaults.standard  // not self.defaults: all members must be set before a closure sees self
        arrivalOverhead = Dictionary(uniqueKeysWithValues: TravelMode.allCases.map { m in
            (m, saved.object(forKey: "arrivalOverhead.\(m.rawValue)") as? Double ?? PickupPlanner.arrivalOverheadMin[m]!)
        })
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
        for id in myOrderIds { LeaveReminder.cancel(orderId: id) }
        name = nil
        cart = [:]
        quote = nil
        cartReady = nil
        orders = []
        plans = [:]
        routes = [:]
        myOrderIds = []
        ordersPath = []
        selectedTab = .menu
        defaults.removeObject(forKey: "customerName")
        defaults.removeObject(forKey: "myOrderIds")
        location.setBackgroundTracking(false)
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

    func updateRestaurantAddress(_ address: String) async {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        restaurantAddress = trimmed.isEmpty ? restaurant.address : trimmed
        defaults.set(restaurantAddress, forKey: "restaurantAddress.\(restaurant.id)")
        restaurantCoordinate = restaurant.coordinate
        await geocodeRestaurant()
        await refreshTrip()
        await quoteCart()
        await replanAll()
    }

    /// Switch the place the kitchen is demoed as (trips and leave times follow).
    func selectRestaurant(_ profile: RestaurantProfile) async {
        restaurant = profile
        defaults.set(profile.id, forKey: "restaurantId")
        restaurantAddress = defaults.string(forKey: "restaurantAddress.\(profile.id)") ?? profile.address
        restaurantCoordinate = profile.coordinate
        await geocodeRestaurant()
        await refreshTrip()
        await quoteCart()
        await replanAll()
    }

    private func geocodeRestaurant() async {
        if let c = await Routing.geocode(restaurantAddress) { restaurantCoordinate = c }
    }

    // MARK: - Loading

    func start() async {
        // Location from the start: it's on the order map and times pickups.
        location.onUpdate = { [weak self] _ in self?.locationDidChange() }
        location.start()
        async let geo: () = geocodeRestaurant()
        await load()
        await geo
        await refreshTrip()
        await replanAll()
    }

    /// Menu, stock and the kitchen's tickets; photos and copy from the web app when configured.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let webMenu = fetchWebMenu()
        do {
            async let menu = client.menu()
            async let inventory = client.inventory()
            async let kitchen = client.orders()
            (self.menu, self.inventory, self.kitchenOrders) = try await (menu, inventory, kitchen)
            self.menu = self.menu.resolvingNames(from: self.inventory)  // Railway recipes carry ids only
            loadedAt = Date()
            loadError = nil
            model = fitModel()
        } catch {
            loadError = error.localizedDescription
        }
        web = await webMenu
        await refreshOrders()
        await quoteCart()
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

    // MARK: - Kitchen model

    /// Tickets the kitchen is working on right now (what "busy" means to the model).
    var kitchenBusy: Double {
        Double(kitchenOrders.filter { $0.status == "RECEIVED" || $0.status == "PREPARING" }.count)
    }

    private func menuItem(_ id: String) -> BarMadeMenuItem? { menu.first { $0.id == id } }

    private func prepMinutes(for lines: [BarMadeOrderLine]) -> Double {
        ReadyTimeModel.prepMinutes(lines.compactMap { menuItem($0.menuItemId) }.map(ReadyTimeModel.prepPrior))
    }

    /// Days of kitchen history the model learns from. Short on purpose: on the
    /// synthetic benchmark (datasets/barmade-forecast) a 3-day window tracked a
    /// slow week and recovered from it best (MAE 2.0 / 3.1 min vs 2.3 / 7.7 for 14 days).
    static let learningWindowDays = 3.0

    /// Learn this kitchen's pace from the tickets it timed recently (RECEIVED -> READY).
    private func fitModel() -> ReadyTimeModel {
        let timed = kitchenOrders.filter { o in
            guard let r = o.time(of: "RECEIVED"), let ready = o.time(of: "READY") else { return false }
            return ready > r
        }
        var recent = timed.filter { Date().timeIntervalSince($0.time(of: "RECEIVED")!) < Self.learningWindowDays * 86400 }
        // A quiet kitchen: widen to a week rather than learn from a handful of tickets.
        if recent.count < 8 { recent = timed.filter { Date().timeIntervalSince($0.time(of: "RECEIVED")!) < 7 * 86400 } }
        let samples: [KitchenSample] = recent.compactMap { o in
            guard let received = o.time(of: "RECEIVED"), let ready = o.time(of: "READY"), ready > received else { return nil }
            // How many other tickets were open when this one came in.
            let busy = kitchenOrders.filter { other in
                other.id != o.id && (other.time(of: "RECEIVED") ?? other.createdAt) <= received
                    && (other.time(of: "READY") ?? other.time(of: "COMPLETED") ?? .distantFuture) > received
            }.count
            let expected = ReadyTimeModel.expectedMinutes(
                prep: prepMinutes(for: o.items), itemCount: o.items.reduce(0) { $0 + $1.quantity },
                busy: Double(busy), when: received)
            return KitchenSample(minutes: ready.timeIntervalSince(received) / 60, expected: expected)
        }
        return .fit(samples)
    }

    /// Minutes until a cart like this would be ready if ordered now.
    func readyEstimate(prep: Double, itemCount: Int, elapsedMin: Double = 0) -> ReadyEstimate {
        model.predict(prep: prep, itemCount: itemCount, busy: kitchenBusy, when: Date(), elapsedMin: elapsedMin)
    }

    /// "Ready in ~N min" for the restaurant card: the quickest dish, ordered now.
    var menuReadyMinutes: Double {
        let quickest = dishes.filter(\.orderable).map(\.prepMin).min() ?? 15
        return readyEstimate(prep: quickest, itemCount: 1).p50
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
        Task { await quoteCart() }
    }

    func setQuantity(_ quantity: Int, of id: String) {
        if quantity <= 0 { cart[id] = nil } else { cart[id] = min(20, quantity) }
        Task { await quoteCart() }
    }

    var cartLines: [(dish: Dish, quantity: Int)] {
        dishes.compactMap { d in cart[d.id].map { (dish: d, quantity: $0) } }
    }
    var cartCount: Int { cart.values.reduce(0, +) }
    var cartTotal: Double { cartLines.reduce(0) { $0 + $1.dish.price * Double($1.quantity) } }

    /// Before ordering: when will it be ready and when should I leave?
    func quoteCart() async {
        let lines = cartLines
        guard !lines.isEmpty else { quote = nil; cartReady = nil; return }
        let ready = readyEstimate(prep: ReadyTimeModel.prepMinutes(lines.map(\.dish.prepMin)), itemCount: cartCount)
        cartReady = ready
        guard let me = location.coordinate else { quote = nil; return }
        let route = await Routing.route(from: me, to: restaurantCoordinate, mode: mode)
        quote = PickupPlanner.plan(now: Date(), route: route.estimate, mode: mode, ready: ready,
                                   arrivalOverheadMin: arrivalOverhead[mode])
    }

    func setMode(_ m: TravelMode) async {
        mode = m
        await refreshTrip()
        await quoteCart()
        await replanAll()
    }

    /// Change the parking / walk-in buffer for a travel mode; quotes and leave times follow.
    func setArrivalOverhead(_ minutes: Double, for m: TravelMode) async {
        let clamped = min(15, max(0, (minutes * 2).rounded() / 2))
        arrivalOverhead[m] = clamped
        defaults.set(clamped, forKey: "arrivalOverhead.\(m.rawValue)")
        await quoteCart()
        await replanAll()
    }

    /// Door to door for the current mode: travel plus the buffer.
    func tripMinutes(_ travelMin: Double) -> Double { travelMin + (arrivalOverhead[mode] ?? 0) }

    // MARK: - Ready when you arrive

    /// A dish timed against your trip: how long the kitchen needs for it if
    /// ordered now, versus how long it takes you to get to the counter.
    struct ArrivalPick: Identifiable {
        let dish: Dish
        let readyMin: Double
        let tripMin: Double
        /// Minutes you would wait (positive) or the food would sit (negative) if you left now.
        var gapMin: Double { readyMin - tripMin }
        var id: String { dish.id }

        var headline: String {
            if gapMin <= PickupPlanner.leaveNowSlackMin && gapMin >= -PickupPlanner.freshHoldMin { return "Ready as you arrive" }
            if gapMin < 0 { return "Ready \(Format.minutes(-gapMin)) before you arrive" }
            return "Leave in \(Format.minutes(gapMin))"
        }
    }

    /// Rank dishes by how well their kitchen time fits the trip, best first.
    /// A gap of 0 means ready the moment you reach the counter. Waiting a
    /// little is better than food sitting, so sitting counts double.
    nonisolated static func rankForArrival(readyMin: [String: Double], tripMin: Double) -> [(id: String, gap: Double)] {
        readyMin.map { (id: $0.key, gap: $0.value - tripMin) }
            .sorted { a, b in
                let ca = a.gap >= 0 ? a.gap : -a.gap * 2
                let cb = b.gap >= 0 ? b.gap : -b.gap * 2
                return ca == cb ? a.id < b.id : ca < cb
            }
    }

    /// Up to three dishes picked for your distance and the kitchen's pace right
    /// now. Empty without a location fix (there's no trip to fit).
    var arrivalPicks: [ArrivalPick] {
        guard let trip else { return [] }
        let tripMin = tripMinutes(trip.durationMin)
        let candidates = dishes.filter(\.orderable)
        let ready = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, readyEstimate(prep: $0.prepMin, itemCount: 1).p50) })
        let byId = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return Self.rankForArrival(readyMin: ready, tripMin: tripMin).prefix(3).compactMap { r in
            byId[r.id].map { ArrivalPick(dish: $0, readyMin: ready[r.id] ?? 0, tripMin: tripMin) }
        }
    }

    /// Route from the phone to the restaurant, for the Map tab.
    func refreshTrip() async {
        guard let me = location.coordinate else { trip = nil; tripLine = nil; return }
        let route = await Routing.route(from: me, to: restaurantCoordinate, mode: mode)
        trip = route.estimate
        tripLine = route.polyline
    }

    /// Walk when the restaurant is close, otherwise drive. Without a fix, keep the setting.
    func suggestMode() {
        guard let me = location.coordinate else { return }
        mode = Routing.haversineKm(me, restaurantCoordinate) <= 1.5 ? .walking : .driving
    }

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
        knownStatuses[order.id] = order.status
        // Remember the quote: "ready ~12:40" said at checkout is what "running late" is measured against.
        if let ready = cartReady {
            let quoted = Date().addingTimeInterval(ready.p50 * 60)
            quotedReady[order.id] = quoted
            lastToldReady[order.id] = quoted
            defaults.set(quotedReady.mapValues(\.timeIntervalSince1970), forKey: "quotedReady")
        }
        upsert(order)
        // Ask in context, like real delivery apps; iOS only prompts once.
        LeaveReminder.requestPermission()
        // Ask once for background tracking so re-planning continues with the app closed.
        location.requestAlways()
        cart = [:]
        quote = nil
        cartReady = nil
        showCart = false
        selectedTab = .orders
        ordersPath = [order.id]
        await refreshPlan(order.id)
        // The kitchen just deducted stock and has one more ticket; show it.
        Task { await load() }
        return order
    }

    /// The newest order still in the kitchen, for the "Track" banner.
    var activeOrder: BarMadeOrder? { orders.first { $0.isOpen } }
    var activePickups: [BarMadeOrder] { orders.filter { $0.isOpen && $0.status != "READY" } }

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
        for o in orders { noteStatus(o) }
        updateBackgroundTracking()
    }

    func refreshOrder(_ id: String) async {
        if let o = try? await client.order(id) { upsert(o) }
    }

    private func upsert(_ order: BarMadeOrder) {
        noteStatus(order)
        if let i = orders.firstIndex(where: { $0.id == order.id }) {
            orders[i] = order
        } else {
            orders.insert(order, at: 0)
            orders.sort { $0.createdAt > $1.createdAt }
        }
        updateBackgroundTracking()
    }

    /// A status change the kitchen made shows up as a notification while
    /// the app is open, and ends the leave reminder once the food is ready.
    private func noteStatus(_ order: BarMadeOrder) {
        let previous = knownStatuses[order.id]
        knownStatuses[order.id] = order.status
        guard let previous, previous != order.status else { return }
        if order.status == "READY" || order.isClosed { LeaveReminder.cancel(orderId: order.id) }
        let body: String
        switch order.status {
        case "PREPARING": body = "The kitchen is cooking your order \(order.displayNumber)."
        case "READY": body = order.fulfillment == "for_here" ? "Your order \(order.displayNumber) is on its way to your table." : "Your order \(order.displayNumber) is ready at the counter."
        case "COMPLETED": body = "Enjoy your meal!"
        case "CANCELLED": body = "Your order \(order.displayNumber) was cancelled."
        default: return
        }
        LeaveReminder.notify(orderId: order.id, title: orderStatusTitle(order.status), body: body)
    }

    // MARK: - Pickup planning

    /// Kitchen estimate for an open order, from how long it has been in already.
    func readyEstimate(for order: BarMadeOrder) -> ReadyEstimate {
        let since = order.time(of: "RECEIVED") ?? order.createdAt
        return readyEstimate(
            prep: prepMinutes(for: order.items), itemCount: order.items.reduce(0) { $0 + $1.quantity },
            elapsedMin: max(0, Date().timeIntervalSince(since) / 60))
    }

    /// Re-plan from where the phone is now and schedule the leave reminder.
    func refreshPlan(_ orderId: String) async {
        guard let order = order(orderId), order.isOpen else {
            plans[orderId] = nil
            routes[orderId] = nil
            LeaveReminder.cancel(orderId: orderId)
            return
        }
        guard let me = location.coordinate else { return }
        let route = await Routing.route(from: me, to: restaurantCoordinate, mode: mode)
        let actualReady = order.status == "READY" ? (order.time(of: "READY") ?? Date()) : nil
        let plan = PickupPlanner.plan(
            now: Date(), route: route.estimate, mode: mode,
            ready: actualReady == nil ? readyEstimate(for: order) : nil, actualReadyAt: actualReady,
            arrivalOverheadMin: arrivalOverhead[mode])
        plans[orderId] = plan
        routes[orderId] = route.polyline
        if plan.shouldWait {
            LeaveReminder.schedule(orderId: orderId, at: plan.leaveAt, restaurant: restaurant.name)
        } else {
            LeaveReminder.cancel(orderId: orderId)
        }
        noteSlip(order, readyAt: plan.readyAt)
    }

    /// The adjustment: when the kitchen's expected ready time slips 5+ minutes
    /// past what the customer was last told, say so (like the old "Running late").
    private func noteSlip(_ order: BarMadeOrder, readyAt: Date) {
        guard order.status != "READY", let told = lastToldReady[order.id] ?? quotedReady[order.id] else { return }
        let slipMin = readyAt.timeIntervalSince(told) / 60
        guard slipMin >= Self.delayAlertMin else { return }
        lastToldReady[order.id] = readyAt
        let total = quotedReady[order.id].map { readyAt.timeIntervalSince($0) / 60 } ?? slipMin
        LeaveReminder.notify(
            orderId: order.id, title: "Running late",
            body: "Your order \(order.displayNumber) is now expected around \(Format.time(readyAt)), about \(Format.minutes(total)) later than quoted. We've moved your leave time.")
    }

    /// Minutes the current estimate is behind the checkout quote (nil if on time or unknown).
    func minutesLate(_ order: BarMadeOrder) -> Double? {
        guard let quoted = quotedReady[order.id], let plan = plans[order.id] else { return nil }
        let late = plan.readyAt.timeIntervalSince(quoted) / 60
        return late >= 1 ? late : nil
    }

    /// Chance the food is more than 10 minutes later than quoted, read off the
    /// model's p50 / p75 / p90 band (the old app's delay-risk badge).
    func delayRisk(_ order: BarMadeOrder) -> Double? {
        guard let quoted = quotedReady[order.id], order.isOpen, order.status != "READY" else { return nil }
        let est = readyEstimate(for: order)
        let now = Date()
        let threshold = quoted.addingTimeInterval(10 * 60).timeIntervalSince(now) / 60  // minutes from now
        let (p50, p75, p90) = (est.p50, est.p75, est.p90)
        let risk: Double
        if threshold <= p50 { risk = 0.5 + 0.4 * min(1, (p50 - threshold) / 10) }
        else if threshold <= p75 { risk = 0.25 + 0.25 * (p75 - threshold) / max(0.1, p75 - p50) }
        else if threshold <= p90 { risk = 0.10 + 0.15 * (p90 - threshold) / max(0.1, p90 - p75) }
        else { risk = 0.05 }
        return min(0.95, max(0.02, risk))
    }

    func replanAll() async {
        for o in orders where o.isOpen { await refreshPlan(o.id) }
    }

    /// Movement: re-quote the cart and re-plan every open order (throttled).
    /// Runs in the background too when "Always" location is granted.
    private func locationDidChange() {
        guard Date().timeIntervalSince(lastReplan) > 15 else { return }
        lastReplan = Date()
        Task {
            await refreshTrip()
            await quoteCart()
            await replanAll()
        }
    }

    /// Keep background tracking on only while a pickup is in progress.
    private func updateBackgroundTracking() {
        location.setBackgroundTracking(!activePickups.isEmpty)
    }
}

/// A place the kitchen is presented as. BarMade has no restaurant profile of its own.
struct RestaurantProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let cuisineLine: String
    let tagline: String
    let address: String
    let coordinate: CLLocationCoordinate2D
    /// Test venue: orders still go to the real kitchen, the app just says so.
    let isQA: Bool

    static func == (a: RestaurantProfile, b: RestaurantProfile) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
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
