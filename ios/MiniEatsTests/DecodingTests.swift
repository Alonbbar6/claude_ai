import XCTest
@testable import MiniEats

/// Guards the Swift <-> Python JSON contract.
final class DecodingTests: XCTestCase {
    func testDecodesOrderWithMicrosecondDatesAndNulls() throws {
        let json = """
        {
          "id": "ord_1", "user_id": "user_alex", "restaurant_id": "rest_pizza",
          "lines": [{"item_id": "pizza_1", "quantity": 2}],
          "status": "courier_dispatched",
          "created_at": "2026-10-07T04:27:18.434223Z",
          "updated_at": "2026-10-07T04:27:18.434223+00:00",
          "route": {"distance_km": 3.08, "duration_min": 9.7, "source": "haversine"},
          "raining": false,
          "quoted_eta": {"eta_minutes": 41.9, "eta_at": "2026-10-07T05:09:12.1Z",
                         "delay_risk": 0.16, "features": {"distance_km": 3.08}},
          "current_eta": null,
          "dispatch": {
            "courier_id": "cour_dev", "courier_name": "Dev",
            "courier_to_restaurant_km": 1.5, "courier_to_restaurant_min": 4.9,
            "ready_at": "2026-10-07T04:44:04.000001Z", "dispatch_at": "2026-10-07T04:39:10Z",
            "expected_pickup_at": "2026-10-07T04:45:34Z", "expected_delivery_at": "2026-10-07T04:56:46Z",
            "pickup_delay_min": 0.0, "route_source": "haversine"
          },
          "history": [{"status": "placed"}]
        }
        """
        let order = try JSONDecoder.api.decode(Order.self, from: Data(json.utf8))
        XCTAssertEqual(order.status, .courierDispatched)
        XCTAssertEqual(order.lines.first?.itemId, "pizza_1")
        XCTAssertEqual(order.itemCount, 2)
        XCTAssertNil(order.currentEta)
        XCTAssertEqual(order.quotedEta?.etaMinutes, 41.9)
        XCTAssertEqual(order.dispatch?.courierName, "Dev")
        XCTAssertEqual(order.createdAt, order.updatedAt)
    }

    func testDecodesWebSocketNotificationWithoutDeliveries() throws {
        let json = """
        {"type": "notification", "data": {
          "id": "ntf_1", "user_id": "user_alex", "order_id": null, "kind": "delayed",
          "title": "Running late", "body": "Sorry", "urgent": true,
          "created_at": "2026-10-07T04:27:18.434223Z"}}
        """
        let msg = try JSONDecoder.api.decode(SocketMessage.self, from: Data(json.utf8))
        XCTAssertEqual(msg.data.title, "Running late")
        XCTAssertNil(msg.data.orderId)
        XCTAssertNil(msg.data.deliveries)
    }

    func testEncodesRequestBodiesAsSnakeCase() throws {
        let body = CreateOrderBody(
            userId: "u", restaurantId: "r", lines: [OrderLine(itemId: "i", quantity: 1)], raining: true)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(body)) as! [String: Any]
        XCTAssertEqual(object["user_id"] as? String, "u")
        XCTAssertEqual(object["restaurant_id"] as? String, "r")
        XCTAssertEqual((object["lines"] as? [[String: Any]])?.first?["item_id"] as? String, "i")

        let prefs = NotificationPrefs(channels: ["push"], quietStart: 22, quietEnd: 8, allowUrgentInQuietHours: true)
        let p = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(prefs)) as! [String: Any]
        XCTAssertEqual(p["quiet_start"] as? Int, 22)
        XCTAssertEqual(p["allow_urgent_in_quiet_hours"] as? Bool, true)
    }
}
