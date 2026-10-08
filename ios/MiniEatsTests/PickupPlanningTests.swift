import XCTest
@testable import MiniEats

/// Ports of the server-side planner and ready-model tests (tests/test_pickup.py,
/// tests/test_ready_model.py), now that both run on the phone.
final class PickupPlanningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_772_636_400)  // 2026-03-04 15:00 UTC
    let ready = ReadyEstimate(p50: 20, p75: 23, p90: 27)

    private func route(_ minutes: Double, km: Double = 3) -> RouteEstimate {
        RouteEstimate(distanceKm: km, durationMin: minutes, source: "test")
    }

    func testCloseByWaitsAndArrivesAtP75() {
        let plan = PickupPlanner.plan(now: now, route: route(8), mode: .driving, ready: ready)
        let trip = 8 + PickupPlanner.arrivalOverheadMin[.driving]!
        XCTAssertEqual(plan.decision, "wait")
        XCTAssertEqual(plan.tripMin, trip)
        XCTAssertEqual(plan.targetArrivalAt, now.addingTimeInterval(23 * 60))
        XCTAssertEqual(plan.leaveAt, now.addingTimeInterval((23 - trip) * 60))
        XCTAssertEqual(plan.arriveAt, plan.targetArrivalAt)
        // Arriving at p75: food sits ~3 min (fresh), customer doesn't wait (at the median).
        XCTAssertEqual(plan.foodWaitMin, 3)
        XCTAssertEqual(plan.yourWaitMin, 0)
        XCTAssertTrue(plan.message.contains("Leave in 13 min"))
    }

    func testFarAwayLeavesNowAndReportsFoodWait() {
        let plan = PickupPlanner.plan(now: now, route: route(35, km: 20), mode: .driving, ready: ready)
        XCTAssertEqual(plan.decision, "leave_now")
        XCTAssertEqual(plan.leaveAt, now)
        XCTAssertEqual(plan.foodWaitMin, 35 + 2 - 20)
        XCTAssertGreaterThan(plan.foodWaitMin, PickupPlanner.freshHoldMin)
        XCTAssertTrue(plan.message.contains("ready about 17 min before you arrive"))
    }

    func testJustInTimeSaysLeaveNowWithoutColdFoodWarning() {
        let plan = PickupPlanner.plan(now: now, route: route(21), mode: .driving, ready: ready)
        XCTAssertEqual(plan.decision, "leave_now")
        XCTAssertLessThanOrEqual(plan.foodWaitMin, PickupPlanner.freshHoldMin)
        XCTAssertTrue(plan.message.contains("gets you there as your food is ready"))
    }

    func testWalkingLeavesEarlierThanDrivingForSameDistance() {
        let drive = PickupPlanner.plan(now: now, route: route(5), mode: .driving, ready: ready)
        let walk = PickupPlanner.plan(now: now, route: route(15), mode: .walking, ready: ready)
        XCTAssertLessThan(walk.leaveAt, drive.leaveAt)
        XCTAssertTrue(walk.message.contains("walk"))
    }

    func testFoodAlreadyReadyMeansGoNow() {
        let readyAt = now.addingTimeInterval(-2 * 60)
        let plan = PickupPlanner.plan(now: now, route: route(6), mode: .driving, ready: nil, actualReadyAt: readyAt)
        XCTAssertEqual(plan.decision, "ready")
        XCTAssertEqual(plan.readyAt, readyAt)
        XCTAssertEqual(plan.leaveAt, now)
        XCTAssertEqual(plan.foodWaitMin, 2 + 6 + 2)
    }

    func testTooFar() {
        let plan = PickupPlanner.plan(now: now, route: route(300, km: 250), mode: .driving, ready: ready)
        XCTAssertEqual(plan.decision, "too_far")
        XCTAssertTrue(plan.message.contains("too far"))
    }

    // MARK: - Pickup timing setting and "ready when you arrive"

    func testOverheadSettingChangesLeaveTime() {
        // 44 min of cooking, 20 min away: with no buffer the timer is exactly 24 min.
        let cooking = ReadyEstimate(p50: 40, p75: 44, p90: 50)
        let exact = PickupPlanner.plan(now: now, route: route(20, km: 10), mode: .driving, ready: cooking, arrivalOverheadMin: 0)
        XCTAssertEqual(exact.decision, "wait")
        XCTAssertEqual(exact.leaveAt, now.addingTimeInterval(24 * 60))
        XCTAssertTrue(exact.message.contains("Leave in 24 min"))
        // The default buffer leaves 2 min earlier; a 5 min buffer, 5 min earlier.
        let byDefault = PickupPlanner.plan(now: now, route: route(20, km: 10), mode: .driving, ready: cooking)
        XCTAssertEqual(byDefault.leaveAt, now.addingTimeInterval(22 * 60))
        let slowParking = PickupPlanner.plan(now: now, route: route(20, km: 10), mode: .driving, ready: cooking, arrivalOverheadMin: 5)
        XCTAssertEqual(slowParking.leaveAt, now.addingTimeInterval(19 * 60))
        XCTAssertEqual(slowParking.tripMin, 25)
    }

    func testRankForArrivalPrefersReadyAsYouWalkIn() {
        // 20 min away. Pasta is ready as you arrive; the pizza needs 10 more minutes (you'd wait);
        // the salad is ready 10 min early (it sits, which counts double); the cola sits 19 min.
        let ranked = CustomerStore.rankForArrival(
            readyMin: ["pizza": 30, "pasta": 20.5, "salad": 10, "cola": 1], tripMin: 20)
        XCTAssertEqual(ranked.map(\.id), ["pasta", "pizza", "salad", "cola"])
        XCTAssertEqual(ranked[0].gap, 0.5, accuracy: 0.001)
        XCTAssertEqual(ranked[2].gap, -10, accuracy: 0.001)
    }

    // MARK: - Ready-time model

    private func predict(_ m: ReadyTimeModel = ReadyTimeModel(), prep: Double = 15, items: Int = 2, busy: Double = 2, elapsed: Double = 0) -> ReadyEstimate {
        m.predict(prep: prep, itemCount: items, busy: busy, when: now, elapsedMin: elapsed)
    }

    func testQuantilesAreOrdered() {
        for busy in stride(from: 0.0, to: 10, by: 3) {
            let e = predict(busy: busy)
            XCTAssertGreaterThan(e.p50, 0)
            XCTAssertLessThanOrEqual(e.p50, e.p75)
            XCTAssertLessThanOrEqual(e.p75, e.p90)
        }
    }

    func testBusierKitchenAndBiggerOrderTakeLonger() {
        XCTAssertGreaterThan(predict(busy: 8).p50, predict(busy: 0).p50)
        XCTAssertGreaterThan(predict(items: 6).p50, predict(items: 1).p50)
    }

    func testElapsedTimeShrinksRemaining() {
        XCTAssertLessThan(predict(elapsed: 8).p50, predict().p50)
    }

    func testRunningLateNeverClaimsReadyNow() {
        let late = predict(elapsed: 120)
        XCTAssertGreaterThanOrEqual(late.p50, 1)
        XCTAssertLessThanOrEqual(late.p50, late.p75)
        XCTAssertLessThanOrEqual(late.p75, late.p90)
    }

    func testDrinksAreGrabAndGo() {
        let cola = BarMadeMenuItem(id: "MENU-005", name: "Coca-Cola", price: 2.99, ingredients: [
            .init(ingredientId: "ING-012", quantity: 1, ingredientName: "Coca-Cola Cans", unit: "cans"),
        ])
        let pizza = BarMadeMenuItem(id: "MENU-001", name: "Margherita", price: 15.99, ingredients: [
            .init(ingredientId: "ING-003", quantity: 1, ingredientName: "Dough", unit: "units"),
            .init(ingredientId: "ING-001", quantity: 200, ingredientName: "Sauce", unit: "ml"),
            .init(ingredientId: "ING-002", quantity: 150, ingredientName: "Mozzarella", unit: "g"),
        ])
        XCTAssertEqual(ReadyTimeModel.prepPrior(for: cola), 1)
        XCTAssertEqual(ReadyTimeModel.prepPrior(for: pizza), 12.5)
        XCTAssertLessThan(predict(prep: 1, items: 1).p50, 3)
    }

    func testFitLearnsKitchenPaceAndIgnoresForgottenTickets() {
        // Prior says 20 min; this kitchen consistently takes 30. One ticket sat for 2 h (nobody tapped).
        let samples = (0..<8).map { _ in KitchenSample(minutes: 30, expected: 20) } + [KitchenSample(minutes: 127, expected: 20)]
        let m = ReadyTimeModel.fit(samples)
        XCTAssertEqual(m.sampleCount, 8)
        XCTAssertGreaterThan(m.kitchenFactor, 1.2)   // learned slower...
        XCTAssertLessThan(m.kitchenFactor, 1.5)      // ...but shrunk toward the prior with few samples
        XCTAssertGreaterThan(predict(m).p50, predict().p50)
        XCTAssertNotNil(m.meanAbsErrorMin)

        // No history: the prior, untouched.
        let empty = ReadyTimeModel.fit([])
        XCTAssertEqual(empty, ReadyTimeModel())
    }

    func testStraightLineFallbackUsesRoadFactorAndSpeed() {
        let a = CLLocationCoordinate2D(latitude: 25.7743, longitude: -80.1925)
        let b = CLLocationCoordinate2D(latitude: 25.7930, longitude: -80.1330)
        let r = Routing.fallback(from: a, to: b, mode: .driving).estimate
        XCTAssertEqual(r.source, "estimate")
        XCTAssertEqual(r.distanceKm, Routing.haversineKm(a, b) * 1.3, accuracy: 0.001)
        XCTAssertEqual(r.durationMin, r.distanceKm / 19 * 60, accuracy: 0.001)
    }
}

import CoreLocation
