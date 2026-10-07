import Foundation

// Mirrors the FastAPI models in app/models.py. JSON keys are snake_case on the
// wire; JSONDecoder.api converts them to camelCase.

struct MenuCategory: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var sort: Int
}

/// One ingredient line of a recipe. Sent as a list (not a dictionary) so
/// ingredient ids are values the snake_case key conversion can't touch.
struct RecipeEntry: Codable, Hashable {
    var ingredientId: String
    var quantity: Double
}

struct MenuItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let price: Double
    // Optional so older payloads still decode.
    var description: String?
    var categoryId: String?
    var available: Bool?
    var soldOut: Bool?
    /// Kitchen minutes for this item; nil = restaurant average. Low values are grab-and-go.
    var prepMin: Double?
    /// Merchant API only; customers never receive recipes.
    var recipe: [RecipeEntry]?

    var isAvailable: Bool { available ?? true }
    var isSoldOut: Bool { soldOut ?? false }
    var orderable: Bool { isAvailable && !isSoldOut }
}

struct Restaurant: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let cuisine: String
    let lat: Double
    let lng: Double
    let avgPrepMin: Double
    let menu: [MenuItem]
    var categories: [MenuCategory]?
    var address: String?
    var phone: String?

    /// Menu grouped for display: categories in order, then uncategorised items.
    var sections: [(title: String, items: [MenuItem])] {
        let cats = (categories ?? []).sorted { $0.sort < $1.sort }
        var result = cats.map { c in (c.name, menu.filter { $0.categoryId == c.id }) }
        let known = Set(cats.map(\.id))
        let other = menu.filter { $0.categoryId == nil || !known.contains($0.categoryId!) }
        if !other.isEmpty { result.append((cats.isEmpty ? "Menu" : "More", other)) }
        return result.filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
    }
}

struct NotificationPrefs: Codable, Hashable {
    var channels: [String]
    var quietStart: Int
    var quietEnd: Int
    var allowUrgentInQuietHours: Bool
}

struct AppUser: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let phone: String
    let email: String
    let lat: Double
    let lng: Double
    var prefs: NotificationPrefs
}

struct OrderLine: Codable, Hashable {
    let itemId: String
    let quantity: Int
}

struct LatLngPoint: Codable, Hashable {
    let lat: Double
    let lng: Double
}

struct Route: Codable, Hashable {
    let distanceKm: Double
    let durationMin: Double
    let source: String  // "google" | "haversine"
}

struct EtaPrediction: Codable, Hashable {
    let etaMinutes: Double
    let etaAt: Date
    let delayRisk: Double
}

/// Response of POST /api/predict/eta — a quote shown before ordering.
struct EtaQuote: Codable, Hashable {
    let etaMinutes: Double
    let etaAt: Date
    let delayRisk: Double
    let route: Route
    var destination: QuoteDestination?
    var breakdown: EtaBreakdown?

    var toCurrentLocation: Bool { destination?.source == "current_location" }
}

struct DispatchPlan: Codable, Hashable {
    let courierId: String
    let courierName: String
    let courierToRestaurantKm: Double
    let courierToRestaurantMin: Double
    let readyAt: Date
    let dispatchAt: Date
    let expectedPickupAt: Date
    let expectedDeliveryAt: Date
    let pickupDelayMin: Double
    let routeSource: String
}

enum OrderStatus: String, Codable, CaseIterable {
    case placed
    case confirmed
    case preparing
    case ready  // pickup: on the counter
    case courierDispatched = "courier_dispatched"
    case pickedUp = "picked_up"
    case delivered
    case collected  // pickup: customer has it
    case cancelled

    /// Happy-path steps shown in the tracking timeline.
    static let timeline: [OrderStatus] = [.placed, .confirmed, .preparing, .courierDispatched, .pickedUp, .delivered]
    static let pickupTimeline: [OrderStatus] = [.placed, .confirmed, .preparing, .ready, .collected]

    var title: String {
        switch self {
        case .placed: "Order placed"
        case .confirmed: "Restaurant confirmed"
        case .preparing: "Preparing your food"
        case .ready: "Ready for pickup"
        case .collected: "Picked up"
        case .courierDispatched: "Courier heading to restaurant"
        case .pickedUp: "Picked up, on the way"
        case .delivered: "Delivered"
        case .cancelled: "Cancelled"
        }
    }

    var icon: String {
        switch self {
        case .placed: "checkmark.circle"
        case .confirmed: "storefront"
        case .preparing: "frying.pan"
        case .ready: "bag.fill"
        case .collected: "checkmark.seal.fill"
        case .courierDispatched: "bicycle"
        case .pickedUp: "car.fill"
        case .delivered: "house.fill"
        case .cancelled: "xmark.circle"
        }
    }

    var isClosed: Bool { self == .delivered || self == .collected || self == .cancelled }
}

enum Fulfillment: String, Codable, CaseIterable {
    case delivery, pickup
}

enum TravelMode: String, Codable, CaseIterable {
    case driving, walking

    var label: String { self == .driving ? "Drive" : "Walk" }
    var icon: String { self == .driving ? "car.fill" : "figure.walk" }
}

/// When to leave for pickup so you arrive as the food comes out.
/// Mirrors app/models.py PickupPlan.
struct PickupPlan: Codable, Hashable {
    let decision: String  // wait | leave_now | ready | too_far
    let message: String
    let mode: TravelMode
    let distanceKm: Double
    let travelMin: Double
    let tripMin: Double
    let routeSource: String
    let readyAt: Date
    let readyBy: Date
    let targetArrivalAt: Date
    let leaveAt: Date
    let arriveAt: Date
    let foodWaitMin: Double
    let yourWaitMin: Double
    let computedAt: Date

    var shouldWait: Bool { decision == "wait" }
    /// Minutes from the quote to the food being ready.
    var readyInMin: Double { max(0, readyAt.timeIntervalSince(computedAt) / 60) }
    var verb: String { mode == .driving ? "drive" : "walk" }
}

struct Order: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let restaurantId: String
    let lines: [OrderLine]
    let status: OrderStatus
    let createdAt: Date
    let updatedAt: Date
    let route: Route
    let raining: Bool
    let quotedEta: EtaPrediction?
    let currentEta: EtaPrediction?
    let dispatch: DispatchPlan?
    let fulfillment: Fulfillment
    let pickupLat: Double?
    let pickupLng: Double?
    let deliveryLat: Double?
    let deliveryLng: Double?
    let pickupMode: TravelMode
    let pickup: PickupPlan?
    let readyAt: Date?
    /// Delivery only: the courier's current (simulated) position, refreshed on each poll.
    var courierLocation: LatLngPoint?

    var itemCount: Int { lines.reduce(0) { $0 + $1.quantity } }
    var isPickup: Bool { fulfillment == .pickup }
    var timeline: [OrderStatus] { isPickup ? OrderStatus.pickupTimeline : OrderStatus.timeline }
}

struct DeliveryRecord: Codable, Hashable {
    let notificationId: String
    let channel: String
    let status: String  // sent | failed | deferred | skipped
    let attempts: Int
    let detail: String
}

struct AppNotification: Codable, Identifiable, Hashable {
    let id: String
    let userId: String
    let orderId: String?
    let kind: String
    let title: String
    let body: String
    let urgent: Bool
    let createdAt: Date
    /// Present on GET /api/notifications, absent on WebSocket pushes.
    var deliveries: [DeliveryRecord]?
}

/// Envelope the server sends over /ws/{user_id}.
struct SocketMessage: Decodable {
    let type: String
    let data: AppNotification
}

// MARK: - Request bodies

struct PredictBody: Encodable {
    let userId: String
    let restaurantId: String
    let itemCount: Int
    let raining: Bool
    /// Current location: quote delivery to here instead of the saved address.
    var lat: Double? = nil
    var lng: Double? = nil
    /// Cart lines, so kitchen time matches the items (grab-and-go vs cooked).
    var lines: [OrderLine]? = nil
}

/// Where a delivery's minutes go (app/orders.py delivery_breakdown).
struct EtaBreakdown: Codable, Hashable {
    let kitchenMin: Double
    let courierToRestaurantMin: Double?
    let pickupHandoffMin: Double
    let driveToYouMin: Double
    let dropoffHandoffMin: Double
    let totalMin: Double
    let grabAndGo: Bool
}

struct QuoteDestination: Codable, Hashable {
    let lat: Double
    let lng: Double
    let source: String  // current_location | saved_address
}

struct CreateOrderBody: Encodable {
    let userId: String
    let restaurantId: String
    let lines: [OrderLine]
    let raining: Bool
    var fulfillment: Fulfillment = .delivery
    var pickupLat: Double? = nil
    var pickupLng: Double? = nil
    var pickupMode: TravelMode = .driving
    var deliveryLat: Double? = nil
    var deliveryLng: Double? = nil
}

struct PickupQuoteBody: Encodable {
    let userId: String
    let restaurantId: String
    let itemCount: Int
    let lat: Double?
    let lng: Double?
    let mode: TravelMode
    var lines: [OrderLine]? = nil
}

struct PickupPlanBody: Encodable {
    let lat: Double?
    let lng: Double?
    let mode: TravelMode?
}
