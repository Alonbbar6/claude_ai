import XCTest

/// End to end against a BarMade API: name → menu → cart → order → live tracker.
/// Runs against the local stub by default (`node scripts/barmade-stub.mjs`);
/// set TEST_RUNNER_SERVER_URL to point elsewhere. Never run it against the
/// team's real kitchen: every order deducts real stock.
final class OrderFlowUITests: XCTestCase {
    // xcodebuild passes TEST_RUNNER_SERVER_URL to the runner as SERVER_URL.
    private let server = ProcessInfo.processInfo.environment["SERVER_URL"] ?? "http://127.0.0.1:8787"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlaceOrderAndWatchTheKitchenMoveIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-barMadeServerURL", server, "-uiTestReset"]
        // Location / notification permission sheets: allow and carry on.
        addUIInterruptionMonitor(withDescription: "permissions") { alert in
            for title in ["Allow While Using App", "Allow Once", "Allow"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        app.launch()

        // Welcome: name only.
        let name = app.textFields["name-field"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Alonso")
        shot(app, "1-welcome")
        app.buttons["Start ordering →"].tap()

        // Menu from the kitchen: open a dish with plenty of stock (Coca-Cola, last in the list), add two.
        let first = app.buttons["dish-MENU-001"]
        XCTAssertTrue(first.waitForExistence(timeout: 70), "menu did not load from \(server)")
        shot(app, "2-menu")

        // Map tab: you, the restaurant and the trip.
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip-card"].waitForExistence(timeout: 10))
        sleep(4)  // routing + map tiles
        shot(app, "2a-map")
        app.tabBars.buttons["Menu"].tap()
        app.swipeUp()
        let dish = app.buttons["dish-MENU-005"]
        XCTAssertTrue(dish.waitForExistence(timeout: 5))
        dish.tap()
        let add = app.buttons["add-to-order"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        app.buttons["plus"].firstMatch.tap()  // quantity 2
        shot(app, "2b-dish")
        add.tap()
        let view = app.buttons["view-order"]
        XCTAssertTrue(view.waitForExistence(timeout: 5))
        view.tap()

        // Cart: for here, table 7.
        let forHere = app.descendants(matching: .any).matching(identifier: "fulfillment-for_here").firstMatch
        XCTAssertTrue(forHere.waitForExistence(timeout: 5))
        forHere.tap()
        let table = app.textFields["table-field"]
        XCTAssertTrue(table.waitForExistence(timeout: 3))
        table.tap()
        table.typeText("7")
        shot(app, "3-cart")
        app.buttons["place-order"].tap()

        // Tracker: the kitchen has it.
        let number = app.staticTexts["order-number"]
        XCTAssertTrue(number.waitForExistence(timeout: 20), "order was not placed")
        // The first order asks for notification permission (system sheet).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow"].waitForExistence(timeout: 3) { springboard.buttons["Allow"].tap() }
        XCTAssertTrue(app.staticTexts["The kitchen has your order"].waitForExistence(timeout: 5))
        // With a location fix, the planner says when to leave (a drink is ready in ~2 min: leave now).
        XCTAssertTrue(app.staticTexts["leave-now"].waitForExistence(timeout: 20)
                      || app.staticTexts["leave-countdown"].exists, "no pickup plan shown")
        XCTAssertTrue(app.otherElements["tracking-map"].exists || app.maps.firstMatch.exists)
        shot(app, "4-received")

        // The kitchen (any client of the API, here the test itself) moves it; the phone follows.
        let order = try newestOrder()
        XCTAssertEqual(order["customerName"] as? String, "Alonso")
        XCTAssertEqual(order["fulfillment"] as? String, "for_here")
        XCTAssertEqual(order["tableNumber"] as? String, "7")
        XCTAssertEqual(order["source"] as? String, "barmade-ios")
        let id = order["id"] as! String

        try setStatus(id, "PREPARING")
        XCTAssertTrue(app.staticTexts["They're cooking it now"].waitForExistence(timeout: 10))
        try setStatus(id, "READY")
        XCTAssertTrue(app.staticTexts["Ready! It's on its way to your table"].waitForExistence(timeout: 10))
        shot(app, "5-ready")
        try setStatus(id, "COMPLETED")
        XCTAssertTrue(app.staticTexts["Enjoy your meal"].waitForExistence(timeout: 10))
        shot(app, "6-completed")

        // Orders tab lists it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Picked up"].waitForExistence(timeout: 5))
    }

    // MARK: - Talking to the kitchen API from the test

    private func newestOrder() throws -> [String: Any] {
        let data = try request("GET", "/api/orders")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let orders = json["data"] as! [[String: Any]]
        // Newest first on the stub and the real API.
        return orders.first!
    }

    private func setStatus(_ id: String, _ status: String) throws {
        _ = try request("PATCH", "/api/orders/\(id)/status", body: ["status": status])
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Data {
        var req = URLRequest(url: URL(string: server + path)!)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: Data?
        var failure: Error?
        let done = expectation(description: method + path)
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { failure = error }
            else if let code = (response as? HTTPURLResponse)?.statusCode, code >= 300 { failure = NSError(domain: "http", code: code) }
            else { result = data }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 70)
        if let failure { throw failure }
        return result ?? Data()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let image = app.screenshot().pngRepresentation
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "\(name).png", payload: image, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {  // TEST_RUNNER_SHOT_DIR on the command line
            try? image.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
    }
}
