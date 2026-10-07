import XCTest

/// End-to-end restaurant flow against a running backend: toggle availability,
/// create a menu item with a recipe, restock a low ingredient, and check the
/// customer-facing menu reflects each change.
///
/// Server defaults to http://127.0.0.1:8000; override with
/// TEST_RUNNER_SERVER_URL. Use a fresh backend: this test changes its data.
final class MerchantUITests: XCTestCase {
    private var app: XCUIApplication!
    private var server: String { ProcessInfo.processInfo.environment["SERVER_URL"] ?? "http://127.0.0.1:8000" }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-merchantRestaurantId", "rest_burger", "-merchantServerURL", server]
        app.launch()
    }

    func testMenuAndInventory() throws {
        XCTAssertTrue(app.staticTexts["Classic Burger"].waitForExistence(timeout: 15), "menu did not load")
        shot("m1_menu")

        // 1. Turn Fries off -> customers see it unavailable; turn it back on.
        let fries = app.switches["Fries available"]
        XCTAssertTrue(fries.exists)
        fries.switches.firstMatch.tap()
        waitFor("Fries turned off for customers") { self.customerItem("burger_2")?["available"] as? Bool == false }
        shot("m2_fries_off")
        fries.switches.firstMatch.tap()
        waitFor("Fries back on") { self.customerItem("burger_2")?["available"] as? Bool == true }

        // 2. New item with a recipe.
        app.buttons["New item"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Veggie Burger")
        let price = app.textFields["price-field"]
        price.tap()
        price.typeText("9.5")
        // Number pad has no return key; the form adds a "Done" button above it.
        app.toolbars.buttons["Done"].tap()
        let addIngredient = app.buttons["Add ingredient"]
        if !addIngredient.isHittable { app.swipeUp() }
        addIngredient.tap()
        let buns = app.descendants(matching: .any)["Burger buns (each)"].firstMatch
        XCTAssertTrue(buns.waitForExistence(timeout: 5), "ingredient menu did not open")
        buns.tap()
        XCTAssertTrue(app.staticTexts["Burger buns"].waitForExistence(timeout: 3), "ingredient not added to recipe")
        shot("m3_new_item")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Veggie Burger"].waitForExistence(timeout: 5))
        waitFor("Veggie Burger on the customer menu at $9.50") {
            self.customerMenu()?.contains { $0["name"] as? String == "Veggie Burger" && $0["price"] as? Double == 9.5 } == true
        }

        // 3. Inventory: patties are seeded below their alert level; restock to par.
        app.tabBars.buttons["Inventory"].tap()
        let patties = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Beef patties'")).firstMatch
        XCTAssertTrue(patties.waitForExistence(timeout: 5))
        XCTAssertTrue(patties.label.contains("Low"), "patties should show as low: \(patties.label)")
        shot("m4_inventory")
        patties.tap()
        XCTAssertEqual(app.staticTexts["on-hand"].label, "14")
        app.buttons["Restock"].tap()
        // Quantity is prefilled with the suggested reorder (par 80 - 14 on hand).
        XCTAssertEqual(app.textFields["quantity-field"].value as? String, "66")
        app.buttons["Save"].tap()
        let onHand = app.staticTexts["on-hand"]
        expectation(for: NSPredicate(format: "label == '80'"), evaluatedWith: onHand)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Restock"].firstMatch.waitForExistence(timeout: 5), "history should show the restock")
        shot("m5_restocked")
    }

    // MARK: - Helpers

    private func customerMenu() -> [[String: Any]]? {
        guard let rs = fetchJSON("/api/restaurants") as? [[String: Any]],
              let grill = rs.first(where: { $0["id"] as? String == "rest_burger" }) else { return nil }
        return grill["menu"] as? [[String: Any]]
    }

    private func customerItem(_ id: String) -> [String: Any]? {
        customerMenu()?.first { $0["id"] as? String == id }
    }

    private func fetchJSON(_ path: String) -> Any? {
        let done = expectation(description: "GET \(path)")
        var result: Any?
        URLSession.shared.dataTask(with: URL(string: server + path)!) { data, _, _ in
            result = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return result
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
