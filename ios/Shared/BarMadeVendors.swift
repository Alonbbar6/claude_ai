import Foundation

// Purchasing side of the BarMade backend (Railway "barmade-backend"):
// vendors the manager buys from, what each one charges per pack, the
// purchase orders that were emailed to them, and the shopping cart being
// assembled. The manager dashboard creates and edits these; the phone
// reads them.

struct BarMadeVendor: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let email: String
    var phone: String?
    var notes: String?
    var relationship: String       // local | regional | corporate
    var createdAt: Date?
    var products: [BarMadeVendorProduct]
    var productCount: Int?

    enum CodingKeys: String, CodingKey { case id, name, email, phone, notes, relationship, createdAt, products, productCount }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        phone = try c.decodeIfPresent(String.self, forKey: .phone).flatMap { $0.isEmpty ? nil : $0 }
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        relationship = try c.decodeIfPresent(String.self, forKey: .relationship) ?? "regional"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        products = try c.decodeIfPresent([BarMadeVendorProduct].self, forKey: .products) ?? []
        productCount = try c.decodeIfPresent(Int.self, forKey: .productCount)
    }

    /// Products listed, or the count when the list endpoint only sends a number.
    var productTotal: Int { products.isEmpty ? (productCount ?? 0) : products.count }

    /// How the manager dashboard labels the relationship (it sets the tone of order emails).
    var relationshipLabel: String {
        switch relationship {
        case "local": "Local"
        case "corporate": "Corporate"
        default: "Regional"
        }
    }
}

struct BarMadeVendorProduct: Decodable, Identifiable, Hashable {
    let id: String
    let vendorId: String?
    let ingredientId: String
    let ingredientName: String
    let pricePerPack: Double
    let packLabel: String?
}

struct BarMadePurchaseOrder: Decodable, Identifiable, Hashable {
    let id: String
    let vendorId: String
    let vendorName: String
    let status: String             // draft | sent | received | cancelled
    let total: Double
    var emailTo: String?
    var emailSubject: String?
    var emailBody: String?
    let createdAt: Date
    var receivedAt: Date?
    var items: [BarMadePurchaseOrderItem] = []

    enum CodingKeys: String, CodingKey { case id, vendorId, vendorName, status, total, emailTo, emailSubject, emailBody, createdAt, receivedAt, items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        vendorId = try c.decodeIfPresent(String.self, forKey: .vendorId) ?? ""
        vendorName = try c.decodeIfPresent(String.self, forKey: .vendorName) ?? "Vendor"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "sent"
        total = try c.decodeIfPresent(Double.self, forKey: .total) ?? 0
        emailTo = try c.decodeIfPresent(String.self, forKey: .emailTo)
        emailSubject = try c.decodeIfPresent(String.self, forKey: .emailSubject)
        emailBody = try c.decodeIfPresent(String.self, forKey: .emailBody)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        receivedAt = try c.decodeIfPresent(Date.self, forKey: .receivedAt)
        items = try c.decodeIfPresent([BarMadePurchaseOrderItem].self, forKey: .items) ?? []
    }

    /// Still with the vendor (not delivered, not cancelled).
    var isOpen: Bool { !["received", "cancelled"].contains(status.lowercased()) }
    var title: String { emailSubject?.isEmpty == false ? emailSubject! : "Order from \(vendorName)" }
}

struct BarMadePurchaseOrderItem: Decodable, Identifiable, Hashable {
    let id: String
    let ingredientId: String
    let ingredientName: String
    let packs: Double
    let packSize: Double
    let unit: String
    let pricePerPack: Double
    let lineTotal: Double

    /// Base units this line delivers (packs × pack size).
    var units: Double { packs * packSize }
}

struct BarMadeCartItem: Decodable, Identifiable, Hashable {
    let id: String
    let ingredientId: String
    let ingredientName: String
    let quantity: Double
    let unit: String
    var status: String = "pending"
    var addedAt: Date?
    var packSize: Double?
    var packLabel: String?

    enum CodingKeys: String, CodingKey { case id, ingredientId, ingredientName, quantity, unit, status, addedAt, packSize, packLabel }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ingredientId = try c.decode(String.self, forKey: .ingredientId)
        ingredientName = try c.decodeIfPresent(String.self, forKey: .ingredientName) ?? ingredientId
        quantity = try c.decodeIfPresent(Double.self, forKey: .quantity) ?? 0
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt)
        packSize = try c.decodeIfPresent(Double.self, forKey: .packSize)
        packLabel = try c.decodeIfPresent(String.self, forKey: .packLabel)
    }
}

struct BarMadeCart: Decodable, Hashable {
    var items: [BarMadeCartItem] = []
    var count: Int = 0

    init() {}

    enum CodingKeys: String, CodingKey { case items, count }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([BarMadeCartItem].self, forKey: .items) ?? []
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? items.count
    }
}

/// Vendors, purchase orders and the cart, loaded together.
struct BarMadePurchasing {
    var vendors: [BarMadeVendor] = []
    var purchaseOrders: [BarMadePurchaseOrder] = []
    var cart = BarMadeCart()
    var updatedAt: Date?

    func orders(for vendorId: String) -> [BarMadePurchaseOrder] {
        purchaseOrders.filter { $0.vendorId == vendorId }
    }

    func spend(with vendorId: String) -> Double {
        orders(for: vendorId).filter { $0.status.lowercased() != "cancelled" }.reduce(0) { $0 + $1.total }
    }
}

extension BarMadeClient {
    func vendors() async throws -> [BarMadeVendor] { try await list("/api/vendors") }
    func purchaseOrders() async throws -> [BarMadePurchaseOrder] { try await list("/api/purchase-orders") }
    func cart() async throws -> BarMadeCart { try await get("/api/cart", as: BarMadeCart.self) }

    /// Only the Railway backend has purchasing; on an older backend these
    /// routes are 404 and the caller shows the section as unavailable.
    func purchasing() async throws -> BarMadePurchasing {
        async let vendors = vendors()
        async let orders = purchaseOrders()
        async let cart = cart()
        return try await BarMadePurchasing(
            vendors: vendors.sorted { $0.name < $1.name },
            purchaseOrders: orders.sorted { $0.createdAt > $1.createdAt },
            cart: cart, updatedAt: Date())
    }
}
