import XCTest

/// The kitchen moves a customer's ticket forward. Against the local stub by
/// default (`node scripts/barmade-stub.mjs`); TEST_RUNNER_SERVER_URL overrides.
final class MerchantUITests: XCTestCase {
    // xcodebuild passes TEST_RUNNER_SERVER_URL to the runner as SERVER_URL.
    private let server = ProcessInfo.processInfo.environment["SERVER_URL"] ?? "http://127.0.0.1:8787"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testMoveATicketFromReceivedToReady() throws {
        // A customer (here: the test, same call the iPhone app makes) places an order.
        let placed = try request("POST", "/api/orders", body: [
            "items": [["menuItemId": "MENU-005", "quantity": 1]],
            "channel": "barmade", "source": "barmade-ios", "fulfillment": "to_go", "customerName": "María",
        ])
        let id = ((try JSONSerialization.jsonObject(with: placed) as! [String: Any])["data"] as! [String: Any])["id"] as! String

        let app = XCUIApplication()
        app.launchArguments = ["-barMadeServerURL", server]
        app.launch()
        app.tabBars.buttons["Orders"].tap()

        let advance = app.buttons["advance-\(id)"]
        XCTAssertTrue(advance.waitForExistence(timeout: 70), "ticket \(id) did not show up")
        XCTAssertTrue(app.staticTexts["María"].exists)
        XCTAssertTrue(advance.label.contains("Start preparing"))
        shot(app, "merchant-1-received")

        advance.tap()
        let ready = app.buttons["advance-\(id)"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { ready.label.contains("Mark ready") }, "status did not move to PREPARING")
        ready.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { app.buttons["advance-\(id)"].label.contains("Complete") })
        shot(app, "merchant-2-ready")

        // The API agrees.
        let data = try request("GET", "/api/orders/\(id)")
        let order = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["data"] as! [String: Any]
        XCTAssertEqual(order["status"] as? String, "READY")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
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
