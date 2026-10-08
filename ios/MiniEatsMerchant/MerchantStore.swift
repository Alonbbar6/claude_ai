import Foundation
import Observation

/// Kitchen-side state against the BarMade API: inventory, menu, orders and
/// alerts, refreshed together. Stock and menu are read-only here; the
/// kitchen moves orders through their statuses.
@MainActor
@Observable
final class MerchantStore {
    /// BARMADE_API_URL from the project (via Info.plist), else the team's Render host.
    static let defaultServer = infoPlistURL("BarMadeServerURL") ?? "https://barmade-riw5.onrender.com"

    private(set) var barMadeServerURL: String
    var barMade = BarMadeSnapshot()
    var barMadeError: String?
    /// Vendors, purchase orders and cart (Railway backend only; read-only here).
    var purchasing = BarMadePurchasing()
    var purchasingError: String?
    private var seenAlertIds: Set<String> = []

    init() {
        barMadeServerURL = UserDefaults.standard.string(forKey: "barMadeServerURL") ?? Self.defaultServer
        if let i = CommandLine.arguments.firstIndex(of: "-barMadeServerURL"), i + 1 < CommandLine.arguments.count {
            barMadeServerURL = CommandLine.arguments[i + 1]
        }
    }

    var barMadeClient: BarMadeClient {
        BarMadeClient(baseURL: URL(string: barMadeServerURL) ?? URL(string: Self.defaultServer)!)
    }

    // MARK: - Loading

    func start() async { await reload() }

    func updateBarMadeServerURL(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        barMadeServerURL = trimmed.isEmpty ? Self.defaultServer : trimmed
        UserDefaults.standard.set(barMadeServerURL, forKey: "barMadeServerURL")
        barMade = BarMadeSnapshot(); barMadeError = nil
        await reload()
    }

    func reload() async {
        do {
            barMade = try await barMadeClient.snapshot()
            barMadeError = nil
        } catch {
            barMadeError = error.localizedDescription
        }
        await reloadPurchasing()
    }

    /// Separate from the kitchen snapshot so a backend without vendor routes
    /// still shows stock, menu and tickets.
    func reloadPurchasing() async {
        do {
            purchasing = try await barMadeClient.purchasing()
            purchasingError = nil
        } catch let error as APIError where error.status == 404 {
            purchasingError = "This BarMade server has no vendor data (purchasing lives on the Railway backend)."
        } catch {
            purchasingError = error.localizedDescription
        }
    }

    func vendor(_ id: String) -> BarMadeVendor? { purchasing.vendors.first { $0.id == id } }
    func purchaseOrder(_ id: String) -> BarMadePurchaseOrder? { purchasing.purchaseOrders.first { $0.id == id } }
    var openPurchaseOrders: Int { purchasing.purchaseOrders.filter(\.isOpen).count }

    /// Moves an order on, then reloads so every screen shows it.
    /// Returns an error message, or nil on success.
    func setBarMadeOrderStatus(_ orderId: String, to status: String) async -> String? {
        do {
            try await barMadeClient.setStatus(orderId, to: status)
            await reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func barMadeOrder(_ id: String) -> BarMadeOrder? { barMade.orders.first { $0.id == id } }

    // MARK: - Derived

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
}
