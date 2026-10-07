import Foundation
import SwiftUI
import UIKit

extension View {
    /// Number pads have no return key; give forms a "Done" button above the keyboard.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

// Restaurant-side payloads (app/inventory.py, app/catalog.py).

struct MenuCatalog: Decodable {
    let categories: [MenuCategory]
    let items: [MenuItem]
}

/// An ingredient with its status, stock-out forecast and reorder suggestion.
struct StockItem: Decodable, Identifiable, Hashable {
    let id: String
    let restaurantId: String
    let name: String
    let unit: String
    let onHand: Double
    let lowThreshold: Double
    let par: Double
    let dailyUsage: Double
    let status: String  // ok | low | out
    let usagePerHour: Double
    let hoursLeft: Double?
    let runsOutAt: Date?
    let reorderQty: Double
    let portionsLeft: Int?
    let usedBy: [String]

    var fillRatio: Double { par > 0 ? min(onHand / par, 1) : 0 }
}

struct StockAdjustment: Decodable, Identifiable, Hashable {
    let id: String
    let ingredientId: String
    let delta: Double
    let onHandAfter: Double
    let reason: String  // order | cancel | restock | waste | count
    let note: String
    let orderId: String?
    let at: Date
}

struct InventoryAlert: Decodable, Identifiable, Hashable {
    let id: String
    let ingredientId: String
    let kind: String  // low | out
    let message: String
    let at: Date
}

// MARK: - Request bodies

struct NameBody: Encodable { let name: String }
struct ReorderBody: Encodable { let ids: [String] }

/// Create / full update of a menu item. Always sends `category_id` (even
/// null) so moving an item to "No category" works.
struct ItemBody: Encodable {
    var name: String
    var price: Double
    var description: String
    var categoryId: String?
    var available: Bool
    var recipe: [RecipeEntry]

    enum CodingKeys: String, CodingKey { case name, price, description, categoryId, available, recipe }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(price, forKey: .price)
        try c.encode(description, forKey: .description)
        try c.encode(categoryId, forKey: .categoryId)
        try c.encode(available, forKey: .available)
        try c.encode(recipe, forKey: .recipe)
    }
}

struct AvailabilityBody: Encodable { let available: Bool }

struct IngredientBody: Encodable {
    var name: String
    var unit: String
    var onHand: Double
    var lowThreshold: Double
    var par: Double
    var dailyUsage: Double
}

struct IngredientUpdateBody: Encodable {
    var name: String
    var unit: String
    var lowThreshold: Double
    var par: Double
    var dailyUsage: Double
}

struct StockMoveBody: Encodable {
    let kind: String  // restock | waste | count
    let quantity: Double
    let note: String
}
