import XCTest

/// End-to-end: browse → add to cart → checkout → live tracking → notifications.
/// Needs the backend running at http://127.0.0.1:8000.
///
/// Set TEST_RUNNER_SHOT_DIR=/some/dir when running xcodebuild to save
/// screenshots of each step (simulator only).
final class OrderFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        // Sam has quiet hours off, so every notification is delivered live.
        app.launchArguments = ["-userId", "user_sam", "-serverURL", "http://127.0.0.1:8000"]
        app.launch()
    }

    func testPlaceOrderAndTrackIt() throws {
        let grill = app.staticTexts["Grill House"]
        XCTAssertTrue(grill.waitForExistence(timeout: 15), "restaurants did not load — is the backend running?")
        // ETA quotes from the ML model render next to each restaurant.
        let etas = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' min'"))
        XCTAssertTrue(etas.firstMatch.waitForExistence(timeout: 10), "no ETA quotes")
        shot("1_home")

        grill.tap()
        let addBurger = app.buttons["Add Classic Burger"]
        XCTAssertTrue(addBurger.waitForExistence(timeout: 5))
        addBurger.tap()
        addBurger.tap()
        app.buttons["Add Fries"].tap()
        shot("2_menu")

        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View cart'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Arrives in"].waitForExistence(timeout: 5), "no ETA quote in cart")
        shot("3_cart")

        app.buttons["Place order"].tap()
        dismissNotificationPrompt()

        XCTAssertTrue(app.staticTexts["Arriving in"].waitForExistence(timeout: 10), "tracking screen did not open")
        shot("4_tracking")

        // The backend advances one stage every ~4 s and pushes a notification
        // over the WebSocket each time; wait for the courier dispatch plan.
        XCTAssertTrue(app.staticTexts["Courier leaves"].waitForExistence(timeout: 20), "no dispatch plan")
        sleep(1)
        shot("5_dispatch")

        // "Delivered" also appears in the timeline, so wait on the header's identifier.
        XCTAssertTrue(app.staticTexts["delivered-header"].waitForExistence(timeout: 40), "order never delivered")
        app.swipeUp()
        shot("6_delivered")

        app.tabBars.buttons["Alerts"].tap()
        XCTAssertTrue(app.staticTexts["Order received"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Courier on the way to the restaurant"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["On the way"].firstMatch.exists)
        shot("7_alerts")
    }

    /// Pickup: the app plans when to leave from the phone's location.
    /// Run with the simulator located near Grill House (see ios/README.md).
    func testPickupTellsYouWhenToLeave() throws {
        let grill = app.staticTexts["Grill House"]
        XCTAssertTrue(grill.waitForExistence(timeout: 15), "restaurants did not load — is the backend running?")
        grill.tap()
        let addBurger = app.buttons["Add Classic Burger"]
        XCTAssertTrue(addBurger.waitForExistence(timeout: 5))
        addBurger.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View cart'")).firstMatch.tap()

        app.buttons["Pickup"].tap()
        allowLocationIfAsked()
        XCTAssertTrue(app.staticTexts["Leave at"].waitForExistence(timeout: 10), "no pickup plan in cart")
        sleep(1)
        shot("p1_cart_pickup")

        app.buttons["Place pickup order"].tap()
        dismissNotificationPrompt()

        // Close by: a live "Leave in m:ss" countdown, not "Leave now".
        let countdown = app.staticTexts["leave-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 10), "no leave countdown")
        XCTAssertTrue(app.buttons["Get directions"].exists)
        sleep(1)
        shot("p2_leave_countdown")

        // Walking is slower, so the plan should tell you to leave sooner.
        let before = countdown.label
        app.buttons["Walk"].tap()
        let changed = NSPredicate(format: "label != %@", before)
        expectation(for: changed, evaluatedWith: countdown)
        waitForExpectations(timeout: 10)
        shot("p3_walking")

        // Skip the kitchen ahead (demo control) until the food is ready.
        let ready = app.staticTexts["ready-header"]
        for _ in 0..<4 where !ready.exists {
            app.swipeUp()
            app.buttons["Advance"].tap()
            app.swipeDown()
            _ = ready.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(ready.waitForExistence(timeout: 5), "food never became ready")
        shot("p4_ready")

        app.buttons["I've picked it up"].tap()
        XCTAssertTrue(app.staticTexts["collected-header"].waitForExistence(timeout: 5))
        shot("p5_collected")

        app.tabBars.buttons["Alerts"].tap()
        XCTAssertTrue(app.staticTexts["Ready for pickup"].firstMatch.waitForExistence(timeout: 5))
        shot("p6_alerts")
    }

    private func allowLocationIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow While Using App"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
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
