import Foundation

// BarMade kitchen API: the backend both apps and the customer web app share.
// Two deployments speak slightly different dialects and this client reads both:
//   - Render  (barmade-riw5.onrender.com): {count, data: [...]} envelopes, batch-
//     tracked stock (totalQuantity / batches), menu "ingredients" with names,
//     EXPIRED / EXPIRING_SOON alerts.
//   - Railway (claudeai-production-….up.railway.app, "barmade-backend"): bare
//     arrays, currentStock / daysOfCover, menu "recipeLines" without names,
//     LOW_STOCK alerts, orders with placedAt / businessDate / channel.
// Customers place orders and follow their status; the kitchen moves orders
// along. Stock and menu are read-only for both.

/// How the kitchen labels orders from this app (web orders say "barmade-web").
let barMadeAppSource = "barmade-ios"

/// Shared helper: read the first present key of several spellings.
private extension KeyedDecodingContainer where K == AnyKey {
    func first<T: Decodable>(_ type: T.Type, _ keys: String...) throws -> T? {
        for key in keys {
            if let v = try decodeIfPresent(T.self, forKey: AnyKey(key)) { return v }
        }
        return nil
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

struct BarMadeIngredient: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let unit: String
    let reorderPoint: Double
    /// Usable stock (Render leaves expired batches out; Railway reports currentStock).
    let totalQuantity: Double
    let expiredQuantity: Double
    let status: String  // Render: IN_STOCK…; Railway: ok | low | out | overstock
    let batches: [BarMadeBatch]
    var daysOfCover: Double?
    var avgDailyUsage: Double?
    var packLabel: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        name = try c.decode(String.self, forKey: AnyKey("name"))
        category = try c.first(String.self, "category") ?? ""
        unit = try c.first(String.self, "unit") ?? ""
        reorderPoint = try c.first(Double.self, "reorderPoint", "lowThreshold") ?? 0
        totalQuantity = try c.first(Double.self, "totalQuantity", "currentStock", "quantity") ?? 0
        expiredQuantity = try c.first(Double.self, "expiredQuantity") ?? 0
        status = try c.first(String.self, "status") ?? ""
        batches = try c.first([BarMadeBatch].self, "batches") ?? []
        daysOfCover = try c.first(Double.self, "daysOfCover")
        avgDailyUsage = try c.first(Double.self, "avgDailyUsage")
        packLabel = try c.first(String.self, "packLabel")
    }

    /// ok | low | out, from the server status or else the reorder point.
    var level: String {
        let s = status.lowercased()
        if totalQuantity <= 0 || s.contains("out") { return "out" }
        if totalQuantity <= reorderPoint || s.contains("low") || s.contains("critical") { return "low" }
        return "ok"
    }

    var isOverstock: Bool { status.lowercased().contains("overstock") }

    /// Full bar at twice the reorder point.
    var fillRatio: Double { reorderPoint > 0 ? min(totalQuantity / (reorderPoint * 2), 1) : 1 }

    /// Batches that are expired or about to, with stock left in them.
    var atRiskBatches: [BarMadeBatch] { batches.filter { $0.status != "FRESH" && $0.quantity > 0 } }
}

struct BarMadeBatch: Decodable, Identifiable, Hashable {
    let batchId: String
    let quantity: Double
    let arrivedAt: Date?
    let expiresAt: Date?
    let status: String  // FRESH | EXPIRING_SOON | EXPIRED

    var id: String { batchId }
}

struct BarMadeMenuItem: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let price: Double
    var ingredients: [BarMadeRecipeLine]
    var category: String?
    var key: String?          // Railway slug, e.g. "pizza_margherita"
    var available: Bool = true
    var modifierIds: [String] = []

    init(id: String, name: String, price: Double, ingredients: [BarMadeRecipeLine], category: String? = nil) {
        self.id = id; self.name = name; self.price = price; self.ingredients = ingredients; self.category = category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        name = try c.decode(String.self, forKey: AnyKey("name"))
        price = try c.first(Double.self, "price") ?? 0
        ingredients = try c.first([BarMadeRecipeLine].self, "ingredients", "recipeLines", "recipe") ?? []
        category = try c.first(String.self, "category")
        key = try c.first(String.self, "key")
        available = try c.first(Bool.self, "available") ?? true
        modifierIds = try c.first([String].self, "modifierIds") ?? []
    }

    /// Railway recipe lines carry only ingredient ids; borrow name and unit from stock.
    func resolvingNames(from inventory: [BarMadeIngredient]) -> BarMadeMenuItem {
        guard ingredients.contains(where: { $0.ingredientName.isEmpty }) else { return self }
        let byId = Dictionary(inventory.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var copy = self
        copy.ingredients = ingredients.map { line in
            guard line.ingredientName.isEmpty, let ing = byId[line.ingredientId] else { return line }
            return BarMadeRecipeLine(ingredientId: line.ingredientId, quantity: line.quantity,
                                     ingredientName: ing.name, unit: line.unit.isEmpty ? ing.unit : line.unit)
        }
        return copy
    }
}

extension Array where Element == BarMadeMenuItem {
    func resolvingNames(from inventory: [BarMadeIngredient]) -> [BarMadeMenuItem] {
        map { $0.resolvingNames(from: inventory) }
    }
}

struct BarMadeRecipeLine: Decodable, Hashable {
    let ingredientId: String
    let quantity: Double
    let ingredientName: String   // "" until resolved from inventory
    let unit: String
    var essential: Bool = true

    init(ingredientId: String, quantity: Double, ingredientName: String, unit: String) {
        self.ingredientId = ingredientId; self.quantity = quantity; self.ingredientName = ingredientName; self.unit = unit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        ingredientId = try c.decode(String.self, forKey: AnyKey("ingredientId"))
        quantity = try c.first(Double.self, "quantity") ?? 0
        ingredientName = try c.first(String.self, "ingredientName", "name") ?? ""
        unit = try c.first(String.self, "unit") ?? ""
        essential = try c.first(Bool.self, "essential") ?? true
    }
}

struct BarMadeOrder: Decodable, Identifiable, Hashable {
    let id: String
    let status: String
    let createdAt: Date
    let items: [BarMadeOrderLine]
    let total: Double
    var consumed: [BarMadeConsumption] = []
    // Fields added by the customer apps (web and iOS); older kitchen orders lack them.
    var source: String?
    var customerName: String?
    var fulfillment: String?  // to_go | for_here
    var tableNumber: String?
    var orderNumber: Int?
    var updatedAt: Date?
    var statusHistory: [BarMadeStatusChange]?
    var channel: String?
    var businessDate: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        status = try c.first(String.self, "status") ?? "RECEIVED"
        guard let created = try c.first(Date.self, "createdAt", "placedAt", "placed_at") else {
            throw DecodingError.keyNotFound(AnyKey("createdAt"), .init(codingPath: decoder.codingPath,
                                                                       debugDescription: "order has no createdAt/placedAt"))
        }
        createdAt = created
        items = try c.first([BarMadeOrderLine].self, "items", "lines") ?? []
        total = try c.first(Double.self, "total", "grossTotal") ?? items.reduce(0) { $0 + $1.lineTotal }
        consumed = try c.first([BarMadeConsumption].self, "consumed") ?? []
        source = try c.first(String.self, "source")
        customerName = try c.first(String.self, "customerName", "customer_name")
        fulfillment = try c.first(String.self, "fulfillment")
        tableNumber = try c.first(String.self, "tableNumber", "table_number")
        orderNumber = try c.first(Int.self, "orderNumber", "order_number")
        updatedAt = try c.first(Date.self, "updatedAt", "updated_at")
        statusHistory = try c.first([BarMadeStatusChange].self, "statusHistory", "status_history")
        channel = try c.first(String.self, "channel")
        businessDate = try c.first(String.self, "businessDate", "business_date")
    }

    /// RECEIVED -> PREPARING -> READY -> COMPLETED; CANCELLED possible until READY.
    static let steps = ["RECEIVED", "PREPARING", "READY", "COMPLETED"]

    /// Where the kitchen can move this order. The server checks it too.
    var nextStatuses: [String] {
        switch status {
        case "RECEIVED": ["PREPARING", "CANCELLED"]
        case "PREPARING": ["READY", "CANCELLED"]
        case "READY": ["COMPLETED"]
        default: []
        }
    }

    var isOpen: Bool { !nextStatuses.isEmpty }
    var isClosed: Bool { !isOpen }
    /// "#1001" when the kitchen numbered it, else the id.
    var displayNumber: String { orderNumber.map { "#\($0)" } ?? id }
    var stepIndex: Int { Self.steps.firstIndex(of: status) ?? -1 }

    func time(of step: String) -> Date? {
        statusHistory?.first { $0.status == step }?.at ?? (step == "RECEIVED" ? createdAt : nil)
    }
}

struct BarMadeStatusChange: Decodable, Hashable {
    let status: String
    let at: Date
}

struct BarMadeOrderLine: Decodable, Hashable {
    let menuItemId: String
    let name: String
    let quantity: Int
    let unitPrice: Double
    let lineTotal: Double
    var modifiers: [String] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        menuItemId = try c.first(String.self, "menuItemId", "item_id", "itemKey") ?? ""
        name = try c.first(String.self, "name") ?? menuItemId
        let qty = try c.first(Int.self, "quantity") ?? 1
        let line = try c.first(Double.self, "lineTotal", "line_total")
        let unit = try c.first(Double.self, "unitPrice", "unit_price")
        let price = unit ?? (line.map { $0 / Double(max(qty, 1)) } ?? 0)
        quantity = qty
        unitPrice = price
        lineTotal = line ?? price * Double(qty)
        modifiers = try c.first([String].self, "modifiers") ?? []
    }
}

/// Stock an order used, and which batches it came out of (oldest first).
struct BarMadeConsumption: Decodable, Hashable {
    let ingredientId: String
    let ingredientName: String
    let unit: String
    let quantity: Double
    let batches: [BarMadeBatchUse]
}

struct BarMadeBatchUse: Decodable, Hashable {
    let batchId: String
    let quantity: Double
}

struct BarMadeAlert: Decodable, Identifiable, Hashable {
    let id: String
    let type: String  // EXPIRED | EXPIRING_SOON | LOW_STOCK | OUT_OF_STOCK | ...
    let status: String
    let ingredientId: String?
    let ingredientName: String?
    let batchId: String?
    let quantity: Double?
    let unit: String?
    let expiresAt: Date?
    let createdAt: Date
    let message: String
    var severity: String?
    var reorderPoint: Double?
    var resolution: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.decode(String.self, forKey: AnyKey("id"))
        type = try c.first(String.self, "type") ?? ""
        status = try c.first(String.self, "status") ?? "ACTIVE"
        ingredientId = try c.first(String.self, "ingredientId")
        ingredientName = try c.first(String.self, "ingredientName")
        batchId = try c.first(String.self, "batchId")
        quantity = try c.first(Double.self, "quantity", "currentQuantity")
        unit = try c.first(String.self, "unit")
        expiresAt = try c.first(Date.self, "expiresAt")
        createdAt = try c.first(Date.self, "createdAt") ?? Date()
        message = try c.first(String.self, "message") ?? ""
        severity = try c.first(String.self, "severity")
        reorderPoint = try c.first(Double.self, "reorderPoint")
        resolution = try c.first(String.self, "resolution")
    }

    var isActive: Bool { status.uppercased() == "ACTIVE" }
}

/// Everything loaded from BarMade in one refresh.
struct BarMadeSnapshot {
    var inventory: [BarMadeIngredient] = []
    var menu: [BarMadeMenuItem] = []
    var orders: [BarMadeOrder] = []
    var alerts: [BarMadeAlert] = []
    var updatedAt: Date?
}

/// Body of POST /api/orders. Same fields the customer web app sends, so a
/// phone order and a web order look the same on the kitchen's ticket.
struct BarMadeNewOrder: Encodable {
    struct Line: Encodable {
        let menuItemId: String
        let quantity: Int
        var modifiers: [String] = []
    }

    let items: [Line]
    var channel = "barmade"
    var source = barMadeAppSource
    let fulfillment: String  // to_go | for_here
    let tableNumber: String?
    let customerName: String
}

/// Async client for the BarMade API. List responses are either bare arrays
/// (Railway) or {"count": n, "data": [...]} (Render); single objects may be
/// wrapped in {"data": ...}; errors are {"error": {"code", "message"}}.
struct BarMadeClient {
    let baseURL: URL

    func list<T: Decodable>(_ path: String) async throws -> [T] {
        try await get(path, as: Listing<T>.self).items
    }

    func menu() async throws -> [BarMadeMenuItem] { try await list("/api/menu") }
    func inventory() async throws -> [BarMadeIngredient] { try await list("/api/inventory") }
    func orders() async throws -> [BarMadeOrder] { try await list("/api/orders") }

    /// nil when the kitchen doesn't know the id.
    func order(_ id: String) async throws -> BarMadeOrder? {
        do {
            return try await get("/api/orders/\(id)", as: Single<BarMadeOrder>.self).value
        } catch let error as APIError where error.status == 404 {
            return nil
        }
    }

    func snapshot() async throws -> BarMadeSnapshot {
        async let inventory: [BarMadeIngredient] = list("/api/inventory")
        async let menu: [BarMadeMenuItem] = list("/api/menu")
        async let orders: [BarMadeOrder] = list("/api/orders")
        async let alerts: [BarMadeAlert] = list("/api/alerts")
        let stock = try await inventory
        return try await BarMadeSnapshot(
            inventory: stock, menu: menu.resolvingNames(from: stock),
            orders: orders.sorted { $0.createdAt > $1.createdAt },
            alerts: alerts.sorted { $0.createdAt > $1.createdAt },
            updatedAt: Date())
    }

    /// The kitchen deducts stock and answers 409 when it can't make something.
    func placeOrder(_ body: BarMadeNewOrder) async throws -> BarMadeOrder {
        var request = URLRequest(url: baseURL.appending(path: "/api/orders"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try JSONDecoder.barMade.decode(Single<BarMadeOrder>.self, from: await send(request)).value
    }

    /// RECEIVED -> PREPARING -> READY -> COMPLETED, or CANCELLED before READY.
    /// The customer's order page follows within ~3 s.
    func setStatus(_ orderId: String, to status: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "/api/orders/\(orderId)/status"))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["status": status])
        _ = try await send(request)
    }

    /// A list, wrapped or bare.
    struct Listing<T: Decodable>: Decodable {
        let items: [T]
        init(from decoder: Decoder) throws {
            if let keyed = try? decoder.container(keyedBy: AnyKey.self) {
                items = try keyed.decode([T].self, forKey: AnyKey("data"))
            } else {
                items = try decoder.singleValueContainer().decode([T].self)
            }
        }
    }

    /// One object, wrapped in {"data": ...} or bare.
    struct Single<T: Decodable>: Decodable {
        let value: T
        init(from decoder: Decoder) throws {
            let keyed = try decoder.container(keyedBy: AnyKey.self)
            if keyed.contains(AnyKey("data")), !keyed.contains(AnyKey("id")) {
                value = try keyed.decode(T.self, forKey: AnyKey("data"))
            } else {
                value = try T(from: decoder)
            }
        }
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        try JSONDecoder.barMade.decode(T.self, from: await send(URLRequest(url: baseURL.appending(path: path))))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        // Render's free tier sleeps when idle; the first request can take ~50 s to wake it.
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            throw APIError(message: message ?? "BarMade returned \(status)", status: status)
        }
        return data
    }
}

extension JSONDecoder {
    /// BarMade keys are already camelCase. Timestamps may lack a zone
    /// ("2026-10-06T19:40:00"): order times are the server clock in UTC,
    /// while batch arrival/expiry dates are the kitchen's local calendar.
    static let barMade: JSONDecoder = {
        func formatter(_ zone: TimeZone) -> DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return f
        }
        let local = formatter(.current)
        let utc = formatter(TimeZone(identifier: "UTC")!)
        let utcKeys: Set<String> = ["createdAt", "updatedAt", "at", "placed_at", "placedAt", "resolvedAt"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let trimmed = string.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
            let zoned = utcKeys.contains(decoder.codingPath.last?.stringValue ?? "") ? utc : local
            guard let date = APIDate.parse(string) ?? zoned.date(from: trimmed) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
            }
            return date
        }
        return decoder
    }()
}
