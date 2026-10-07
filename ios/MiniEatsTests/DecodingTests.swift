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
          "history": [{"status": "placed"}],
          "fulfillment": "delivery", "pickup_lat": null, "pickup_lng": null,
          "pickup_mode": "driving", "pickup": null, "ready_at": null
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

    func testDecodesPickupOrderWithPlan() throws {
        let json = """
        {
          "id": "ord_2", "user_id": "user_sam", "restaurant_id": "rest_burger",
          "lines": [{"item_id": "burger_1", "quantity": 1}], "status": "ready",
          "created_at": "2026-10-07T04:00:00.123456Z", "updated_at": "2026-10-07T04:15:00Z",
          "route": {"distance_km": 0.4, "duration_min": 5.2, "source": "haversine"},
          "raining": false, "quoted_eta": null, "current_eta": null, "dispatch": null,
          "history": [], "fulfillment": "pickup", "pickup_lat": 25.793, "pickup_lng": -80.133,
          "pickup_mode": "walking", "ready_at": "2026-10-07T04:15:00Z",
          "pickup": {
            "decision": "ready", "message": "Your food is ready.", "mode": "walking",
            "distance_km": 0.4, "travel_min": 5.2, "trip_min": 5.7, "route_source": "haversine",
            "ready_at": "2026-10-07T04:15:00Z", "ready_by": "2026-10-07T04:15:00Z",
            "target_arrival_at": "2026-10-07T04:15:00Z", "leave_at": "2026-10-07T04:15:00Z",
            "arrive_at": "2026-10-07T04:20:42Z", "food_wait_min": 5.7, "your_wait_min": 0.0,
            "computed_at": "2026-10-07T04:15:00.000001+00:00"
          }
        }
        """
        let order = try JSONDecoder.api.decode(Order.self, from: Data(json.utf8))
        XCTAssertTrue(order.isPickup)
        XCTAssertEqual(order.status, .ready)
        XCTAssertEqual(order.timeline, OrderStatus.pickupTimeline)
        XCTAssertEqual(order.pickupMode, .walking)
        XCTAssertEqual(order.pickup?.decision, "ready")
        XCTAssertEqual(order.pickup?.tripMin, 5.7)
        XCTAssertFalse(order.pickup!.shouldWait)
        XCTAssertNotNil(order.readyAt)
    }

    func testPickupBodyOmitsMissingLocation() throws {
        let body = PickupPlanBody(lat: nil, lng: nil, mode: .walking)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(body)) as! [String: Any]
        XCTAssertEqual(object["mode"] as? String, "walking")
        XCTAssertNil(object["lat"])

        var create = CreateOrderBody(userId: "u", restaurantId: "r", lines: [], raining: false)
        create.fulfillment = .pickup
        create.pickupLat = 1.5
        let c = try JSONSerialization.jsonObject(with: JSONEncoder.api.encode(create)) as! [String: Any]
        XCTAssertEqual(c["fulfillment"] as? String, "pickup")
        XCTAssertEqual(c["pickup_lat"] as? Double, 1.5)
        XCTAssertEqual(c["pickup_mode"] as? String, "driving")
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
