import Foundation

// Mirrors the FastAPI models in app/models.py. JSON keys are snake_case on the
// wire; JSONDecoder.api converts them to camelCase.

struct MenuItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let price: Double
}

struct Restaurant: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let cuisine: String
    let lat: Double
    let lng: Double
    let avgPrepMin: Double
    let menu: [MenuItem]
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
    let pickupMode: TravelMode
    let pickup: PickupPlan?
    let readyAt: Date?

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
}

struct PickupQuoteBody: Encodable {
    let userId: String
    let restaurantId: String
    let itemCount: Int
    let lat: Double?
    let lng: Double?
    let mode: TravelMode
}

struct PickupPlanBody: Encodable {
    let lat: Double?
    let lng: Double?
    let mode: TravelMode?
}
