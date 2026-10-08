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

    // ---- Railway "barmade-backend" dialect (samples captured live on 2026-10-08) ----

    func testDecodesRailwayBareListsMenuInventoryAndAlerts() throws {
        let menu = """
        [{"id": "MENU-015", "key": "garlic_bread", "name": "Garlic Bread", "category": "Appetizer", "price": 7.99,
          "modifierIds": ["extra_cheese"], "available": true,
          "recipeLines": [{"id": "x1", "menuItemId": "MENU-015", "ingredientId": "ING-027", "quantity": 1, "essential": true}]}]
        """
        let items = try JSONDecoder.barMade.decode(BarMadeClient.Listing<BarMadeMenuItem>.self, from: Data(menu.utf8)).items
        XCTAssertEqual(items.first?.key, "garlic_bread")
        XCTAssertEqual(items.first?.category, "Appetizer")
        XCTAssertEqual(items.first?.modifierIds, ["extra_cheese"])
        XCTAssertEqual(items.first?.ingredients.first?.ingredientId, "ING-027")
        XCTAssertEqual(items.first?.ingredients.first?.ingredientName, "")  // Railway sends no names

        let inventory = """
        [{"id": "ING-027", "name": "Italian Bread", "category": "Bakery", "unit": "units", "currentStock": 205,
          "reorderPoint": 8, "targetDays": 7, "avgDailyUsage": 12.5, "daysOfCover": 16.4, "status": "overstock",
          "packSize": 20, "packLabel": "bag of 20"},
         {"id": "ING-004", "name": "Pepperoni", "category": "Meats", "unit": "slices", "currentStock": 300,
          "reorderPoint": 400, "status": "low"}]
        """
        let stock = try JSONDecoder.barMade.decode(BarMadeClient.Listing<BarMadeIngredient>.self, from: Data(inventory.utf8)).items
        XCTAssertEqual(stock[0].totalQuantity, 205)
        XCTAssertEqual(stock[0].level, "ok")
        XCTAssertTrue(stock[0].isOverstock)
        XCTAssertEqual(stock[0].daysOfCover, 16.4)
        XCTAssertTrue(stock[0].batches.isEmpty && stock[0].atRiskBatches.isEmpty)
        XCTAssertEqual(stock[1].level, "low")

        let resolved = items.resolvingNames(from: stock)
        XCTAssertEqual(resolved.first?.ingredients.first?.ingredientName, "Italian Bread")
        XCTAssertEqual(resolved.first?.ingredients.first?.unit, "units")

        let alerts = """
        [{"id": "ALERT-019", "type": "LOW_STOCK", "status": "RESOLVED", "severity": "high", "ingredientId": "ING-002",
          "ingredientName": "Mozzarella Cheese", "currentQuantity": 7960, "reorderPoint": 8000, "unit": "g",
          "message": "Mozzarella Cheese is running low (7960g left, reorder at 8000).",
          "resolution": "Received from Ricardo Molina.", "note": null,
          "createdAt": "2026-10-10T03:30:00.000Z", "updatedAt": null, "resolvedAt": "2026-10-10T03:30:00.000Z"}]
        """
        let a = try JSONDecoder.barMade.decode(BarMadeClient.Listing<BarMadeAlert>.self, from: Data(alerts.utf8)).items
        XCTAssertEqual(a.first?.type, "LOW_STOCK")
        XCTAssertEqual(a.first?.quantity, 7960)
        XCTAssertEqual(a.first?.severity, "high")
        XCTAssertFalse(a.first!.isActive)
        XCTAssertEqual(a.first?.createdAt, APIDate.parse("2026-10-10T03:30:00.000Z"))
    }

    func testDecodesRailwayOrderListAndWrappedDetail() throws {
        let list = """
        [{"id": "ORD-07401", "status": "RECEIVED", "channel": "barmade", "placedAt": "2026-10-11T03:30:00.000Z",
          "businessDate": "2026-10-10", "total": 17.99, "grossTotal": 17.99, "channelFeeRate": 0.1, "channelFee": 1.8,
          "netTotal": 16.19, "source": "barmade-web", "fulfillment": "to_go", "tableNumber": null,
          "customerName": "ricardo Molina", "customerId": "8e3a", "updatedAt": "2026-10-11T03:30:00.000Z",
          "statusHistory": [{"at": "2026-10-11T03:30:00.000Z", "status": "RECEIVED"}],
          "items": [{"id": "cm1", "orderId": "ORD-07401", "menuItemId": "MENU-002", "itemKey": "pizza_pepperoni",
                     "name": "Pepperoni Pizza", "quantity": 1, "unitPrice": 17.99, "lineTotal": 17.99, "modifiers": []}]}]
        """
        let orders = try JSONDecoder.barMade.decode(BarMadeClient.Listing<BarMadeOrder>.self, from: Data(list.utf8)).items
        let o = try XCTUnwrap(orders.first)
        XCTAssertEqual(o.createdAt, APIDate.parse("2026-10-11T03:30:00.000Z"))  // placedAt stands in for createdAt
        XCTAssertEqual(o.channel, "barmade")
        XCTAssertEqual(o.businessDate, "2026-10-10")
        XCTAssertEqual(o.customerName, "ricardo Molina")
        XCTAssertEqual(o.items.first?.unitPrice, 17.99)
        XCTAssertTrue(o.consumed.isEmpty && o.isOpen)

        // GET /api/orders/:id wraps in {"data": …} and omits unitPrice: derive it from the line total.
        let detail = """
        {"data": {"id": "ORD-07401", "status": "PREPARING", "createdAt": "2026-10-11T03:30:00.000Z",
                  "updatedAt": "2026-10-11T03:31:00.000Z", "statusHistory": [{"at": "2026-10-11T03:30:00.000Z", "status": "RECEIVED"}],
                  "total": 35.98, "fulfillment": "to_go", "customerName": "ricardo Molina",
                  "items": [{"menuItemId": "MENU-002", "name": "Pepperoni Pizza", "quantity": 2, "lineTotal": 35.98}]}}
        """
        let d = try JSONDecoder.barMade.decode(BarMadeClient.Single<BarMadeOrder>.self, from: Data(detail.utf8)).value
        XCTAssertEqual(d.status, "PREPARING")
        XCTAssertEqual(d.items.first?.unitPrice, 17.99)
        XCTAssertEqual(d.nextStatuses, ["READY", "CANCELLED"])

        // Render still wraps lists; both dialects decode through the same Listing.
        let wrapped = """
        {"count": 1, "data": [{"id": "ORD-001", "status": "COMPLETED", "createdAt": "2026-10-06T12:15:00", "items": [], "total": 0}]}
        """
        XCTAssertEqual(try JSONDecoder.barMade.decode(BarMadeClient.Listing<BarMadeOrder>.self, from: Data(wrapped.utf8)).items.count, 1)
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
