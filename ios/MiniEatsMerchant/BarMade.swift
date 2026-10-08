import Foundation

// BarMade kitchen API (https://barmade-riw5.onrender.com): batch-tracked
// inventory, menu recipes, orders and expiry alerts, stored in Firestore.
// Read-only from the merchant app.

struct BarMadeIngredient: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let unit: String
    let reorderPoint: Double
    /// Usable stock: expired batches are already left out.
    let totalQuantity: Double
    let expiredQuantity: Double
    let status: String  // IN_STOCK, ...
    let batches: [BarMadeBatch]

    /// ok | low | out, from the server status or else the reorder point.
    var level: String {
        if totalQuantity <= 0 || status.contains("OUT") { return "out" }
        if totalQuantity <= reorderPoint || status.contains("LOW") { return "low" }
        return "ok"
    }

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
    let ingredients: [BarMadeRecipeLine]
}

struct BarMadeRecipeLine: Decodable, Hashable {
    let ingredientId: String
    let quantity: Double
    let ingredientName: String
    let unit: String
}

struct BarMadeOrder: Decodable, Identifiable, Hashable {
    let id: String
    let status: String
    let createdAt: Date
    let items: [BarMadeOrderLine]
    let total: Double
    let consumed: [BarMadeConsumption]
}

struct BarMadeOrderLine: Decodable, Hashable {
    let menuItemId: String
    let name: String
    let quantity: Int
    let unitPrice: Double
    let lineTotal: Double
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
    let type: String  // EXPIRED | EXPIRING_SOON | ...
    let status: String
    let ingredientId: String?
    let ingredientName: String?
    let batchId: String?
    let quantity: Double?
    let unit: String?
    let expiresAt: Date?
    let createdAt: Date
    let message: String
}

/// Everything loaded from BarMade in one refresh.
struct BarMadeSnapshot {
    var inventory: [BarMadeIngredient] = []
    var menu: [BarMadeMenuItem] = []
    var orders: [BarMadeOrder] = []
    var alerts: [BarMadeAlert] = []
    var updatedAt: Date?
}

/// Async client for the BarMade Express API. Responses are wrapped as
/// {"count": n, "data": ...}; errors as {"error": {"code", "message"}}.
struct BarMadeClient {
    let baseURL: URL

    func list<T: Decodable>(_ path: String) async throws -> [T] {
        try await get(path, as: Envelope<[T]>.self).data
    }

    func snapshot() async throws -> BarMadeSnapshot {
        async let inventory: [BarMadeIngredient] = list("/api/inventory")
        async let menu: [BarMadeMenuItem] = list("/api/menu")
        async let orders: [BarMadeOrder] = list("/api/orders")
        async let alerts: [BarMadeAlert] = list("/api/alerts")
        return try await BarMadeSnapshot(
            inventory: inventory, menu: menu,
            orders: orders.sorted { $0.createdAt > $1.createdAt },
            alerts: alerts.sorted { $0.createdAt > $1.createdAt },
            updatedAt: Date())
    }

    private struct Envelope<T: Decodable>: Decodable { let data: T }
    private struct ErrorBody: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        // Render's free tier sleeps when idle; the first request can take ~50 s to wake it.
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            throw APIError(message: message ?? "BarMade returned \(status)")
        }
        return try JSONDecoder.barMade.decode(T.self, from: data)
    }
}

extension JSONDecoder {
    /// BarMade keys are already camelCase. Its timestamps have no zone
    /// ("2026-10-06T19:40:00"): `createdAt` is the server clock in UTC,
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let trimmed = string.replacingOccurrences(of: #"\.\d+$"#, with: "", options: .regularExpression)
            let zoned = decoder.codingPath.last?.stringValue == "createdAt" ? utc : local
            guard let date = APIDate.parse(string) ?? zoned.date(from: trimmed) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
            }
            return date
        }
        return decoder
    }()
}
