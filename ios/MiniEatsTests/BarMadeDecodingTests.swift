import XCTest
@testable import MiniEats

/// Guards the Swift <-> BarMade API JSON contract (shapes checked live on 2026-10-08).
final class BarMadeDecodingTests: XCTestCase {
    func testDecodesCustomerAppOrderWithZonedTimestamps() throws {
        let json = """
        {"data": {
          "id": "ORD-007", "status": "RECEIVED", "channel": "barmade",
          "placed_at": "2026-10-08T02:13:39.823Z", "business_date": "2026-10-07",
          "createdAt": "2026-10-08T02:13:39.823Z",
          "items": [{"menuItemId": "MENU-005", "item_id": "MENU-005", "name": "Coca-Cola",
                     "quantity": 1, "modifiers": [], "unitPrice": 2.99, "lineTotal": 2.99}],
          "total": 2.99, "gross_total": 2.99, "channel_fee_rate": 0.05, "channel_fee": 0.15, "net_total": 2.84,
          "consumed": [{"ingredientId": "ING-012", "ingredientName": "Coca-Cola", "unit": "cans", "quantity": 1,
                        "batches": [{"batchId": "CC-001", "quantity": 1}]}],
          "source": "barmade-web", "fulfillment": "to_go", "tableNumber": null, "customerName": "Aleska",
          "orderNumber": null, "updatedAt": "2026-10-08T02:13:39.823Z",
          "statusHistory": [{"status": "RECEIVED", "at": "2026-10-08T02:13:39.823Z"}]
        }}
        """
        struct Envelope: Decodable { let data: BarMadeOrder }
        let order = try JSONDecoder.barMade.decode(Envelope.self, from: Data(json.utf8)).data
        XCTAssertEqual(order.status, "RECEIVED")
        XCTAssertEqual(order.customerName, "Aleska")
        XCTAssertEqual(order.fulfillment, "to_go")
        XCTAssertNil(order.tableNumber)
        XCTAssertEqual(order.displayNumber, "ORD-007")  // no orderNumber yet
        XCTAssertEqual(order.nextStatuses, ["PREPARING", "CANCELLED"])
        XCTAssertTrue(order.isOpen)
        XCTAssertEqual(order.time(of: "RECEIVED"), APIDate.parse("2026-10-08T02:13:39.823Z"))
        XCTAssertEqual(order.consumed.first?.batches.first?.batchId, "CC-001")
    }

    func testZonelessOrderTimesAreUTCAndBatchDatesAreLocal() throws {
        let json = """
        {"id": "ORD-001", "status": "COMPLETED", "createdAt": "2026-10-06T12:15:00",
         "items": [], "total": 0, "consumed": []}
        """
        let order = try JSONDecoder.barMade.decode(BarMadeOrder.self, from: Data(json.utf8))
        XCTAssertEqual(order.createdAt, APIDate.parse("2026-10-06T12:15:00Z"))
        XCTAssertTrue(order.isClosed)
        XCTAssertNil(order.customerName)

        let batch = """
        {"batchId": "TS-001", "quantity": 5000, "arrivedAt": "2026-10-03T08:00:00",
         "expiresAt": "2026-10-10T23:59:59", "status": "FRESH"}
        """
        let b = try JSONDecoder.barMade.decode(BarMadeBatch.self, from: Data(batch.utf8))
        let local = Calendar.current.dateComponents([.hour, .minute], from: b.arrivedAt!)
        XCTAssertEqual(local.hour, 8)  // kitchen's wall clock, not shifted
        XCTAssertEqual(local.minute, 0)
    }

    func testDecodesMenuAndInventory() throws {
        let menu = """
        {"count": 1, "data": [{"id": "MENU-001", "name": "Margherita Pizza", "price": 15.99,
          "ingredients": [{"ingredientId": "ING-003", "quantity": 1, "ingredientName": "Pizza Dough", "unit": "units"}]}]}
        """
        struct Envelope<T: Decodable>: Decodable { let data: T }
        let items = try JSONDecoder.barMade.decode(Envelope<[BarMadeMenuItem]>.self, from: Data(menu.utf8)).data
        XCTAssertEqual(items.first?.ingredients.first?.ingredientName, "Pizza Dough")

        let inventory = """
        {"id": "ING-002", "name": "Mozzarella Cheese", "category": "Dairy", "unit": "g", "reorderPoint": 5000,
         "totalQuantity": 11500, "expiredQuantity": 0, "status": "IN_STOCK", "batches": []}
        """
        let ing = try JSONDecoder.barMade.decode(BarMadeIngredient.self, from: Data(inventory.utf8))
        XCTAssertEqual(ing.level, "ok")
        XCTAssertEqual(ing.fillRatio, 1)
    }

    func testNewOrderBodyMatchesTheWebApp() throws {
        let body = BarMadeNewOrder(
            items: [.init(menuItemId: "MENU-001", quantity: 2)],
            fulfillment: "for_here", tableNumber: "7", customerName: "María")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any]
        XCTAssertEqual(object["channel"] as? String, "barmade")
        XCTAssertEqual(object["source"] as? String, "barmade-ios")
        XCTAssertEqual(object["fulfillment"] as? String, "for_here")
        XCTAssertEqual(object["tableNumber"] as? String, "7")
        XCTAssertEqual(object["customerName"] as? String, "María")
        XCTAssertEqual((object["items"] as? [[String: Any]])?.first?["menuItemId"] as? String, "MENU-001")
    }

    @MainActor
    func testServingsLeftFollowsTheScarcestIngredient() async {
        let store = CustomerStore()
        let item = BarMadeMenuItem(id: "MENU-001", name: "Pizza", price: 10, ingredients: [
            .init(ingredientId: "ING-003", quantity: 1, ingredientName: "Dough", unit: "units"),
            .init(ingredientId: "ING-001", quantity: 200, ingredientName: "Sauce", unit: "ml"),
        ])
        XCTAssertEqual(store.servingsLeft(item), 0)  // nothing loaded yet
    }
}
