import Foundation

enum TravelMode: String, CaseIterable, Codable {
    case driving, walking

    var label: String { self == .driving ? "Drive" : "Walk" }
    var icon: String { self == .driving ? "car.fill" : "figure.walk" }
    var verb: String { self == .driving ? "drive" : "walk" }
}

struct RouteEstimate: Equatable {
    let distanceKm: Double
    let durationMin: Double
    let source: String  // "apple" (MapKit directions) | "estimate" (straight line)
}

/// When to leave for pickup so you arrive as the food comes out.
struct PickupPlan: Equatable {
    let decision: String  // wait | leave_now | ready | too_far
    let message: String
    let mode: TravelMode
    let distanceKm: Double
    let travelMin: Double
    let tripMin: Double
    let routeSource: String
    let readyAt: Date
    let readyBy: Date
    let targetArrivalAt: Date
    let leaveAt: Date
    let arriveAt: Date
    let foodWaitMin: Double
    let yourWaitMin: Double
    let computedAt: Date

    var shouldWait: Bool { decision == "wait" }
    var tooFar: Bool { decision == "too_far" }
    /// Minutes from the quote to the food being ready.
    var readyInMin: Double { max(0, readyAt.timeIntervalSince(computedAt) / 60) }
    var verb: String { mode.verb }
}

/// Pickup timing: tell the customer when to leave so they arrive as the food
/// comes out. Too early and they wait at the counter; too late and it goes
/// cold. Pure function, same rules as the server-side planner it replaces:
///
///     target_arrival = kitchen p75 ready time (or the actual ready time once known)
///     trip           = travel time from the customer's location + parking / walk-in
///     leave_at       = target_arrival - trip
enum PickupPlanner {
    /// Time from "arrived" to "at the counter".
    static let arrivalOverheadMin: [TravelMode: Double] = [.driving: 2.0, .walking: 0.5]
    /// How long food can sit before it's noticeably worse.
    static let freshHoldMin = 5.0
    /// Beyond this, pickup doesn't make sense.
    static let maxPickupKm = 80.0
    /// Don't say "leave in 0 min"; under this, just say "leave now".
    static let leaveNowSlackMin = 0.5

    /// `arrivalOverheadMin` overrides the parking / walk-in buffer for this plan
    /// (the customer can tune it under Account); nil uses the mode's default.
    static func plan(
        now: Date, route: RouteEstimate, mode: TravelMode, ready: ReadyEstimate?, actualReadyAt: Date? = nil,
        arrivalOverheadMin overhead: Double? = nil
    ) -> PickupPlan {
        let trip = route.durationMin + (overhead ?? arrivalOverheadMin[mode]!)
        let readyAt: Date, readyBy: Date, target: Date
        if let actual = actualReadyAt {
            readyAt = actual; readyBy = actual; target = actual
        } else {
            let r = ready ?? ReadyEstimate(p50: 15, p75: 19, p90: 24)
            readyAt = now.addingTimeInterval(r.p50 * 60)
            target = now.addingTimeInterval(r.p75 * 60)
            readyBy = now.addingTimeInterval(r.p90 * 60)
        }

        let idealLeave = target.addingTimeInterval(-trip * 60)
        let decision: String
        let leaveAt: Date
        if route.distanceKm > maxPickupKm {
            decision = "too_far"; leaveAt = now
        } else if actualReadyAt != nil {
            decision = "ready"; leaveAt = now
        } else if idealLeave > now.addingTimeInterval(leaveNowSlackMin * 60) {
            decision = "wait"; leaveAt = idealLeave
        } else {
            decision = "leave_now"; leaveAt = now
        }

        let arriveAt = leaveAt.addingTimeInterval(trip * 60)
        let foodWait = max(0, arriveAt.timeIntervalSince(readyAt) / 60)
        let yourWait = max(0, readyAt.timeIntervalSince(arriveAt) / 60)

        return PickupPlan(
            decision: decision,
            message: message(decision, leaveIn: leaveAt.timeIntervalSince(now) / 60, trip: trip,
                             foodWait: foodWait, mode: mode, km: route.distanceKm),
            mode: mode,
            distanceKm: route.distanceKm,
            travelMin: route.durationMin,
            tripMin: round1(trip),
            routeSource: route.source,
            readyAt: readyAt,
            readyBy: readyBy,
            targetArrivalAt: target,
            leaveAt: leaveAt,
            arriveAt: arriveAt,
            foodWaitMin: round1(foodWait),
            yourWaitMin: round1(yourWait),
            computedAt: now)
    }

    private static func message(_ decision: String, leaveIn: Double, trip: Double, foodWait: Double, mode: TravelMode, km: Double) -> String {
        let tripText = "\(max(1, Int(trip.rounded()))) min \(mode.verb)"
        switch decision {
        case "too_far": return "You're \(Int(km.rounded())) km away, too far for pickup."
        case "ready": return "Head over now, it's a \(tripText)."
        case "wait": return "Leave in \(max(1, Int(leaveIn.rounded()))) min so you arrive as your food comes out (\(tripText))."
        default:
            if foodWait > freshHoldMin {
                return "Leave now. Your food will be ready about \(Int(foodWait.rounded())) min before you arrive."
            }
            return "Leave now. A \(tripText) gets you there as your food is ready."
        }
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
