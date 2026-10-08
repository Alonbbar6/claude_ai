import Foundation

/// Minutes from now until the food is ready, at three confidence levels.
/// p50 is the most likely time, p75 what pickups are planned against, p90
/// "almost surely ready by".
struct ReadyEstimate: Equatable {
    let p50: Double
    let p75: Double
    let p90: Double
}

/// One finished order as the kitchen actually timed it (RECEIVED -> READY).
struct KitchenSample: Equatable {
    let minutes: Double
    /// What the prior predicted for that order, so the model can learn how
    /// this kitchen runs relative to it.
    let expected: Double
}

/// Kitchen ready-time model that runs on the phone.
///
/// The old server used quantile gradient boosting trained on synthetic data.
/// Here the structure of that model (prep time, item count, how busy the
/// kitchen is, rush hour, weekend; a right-skewed spread) is the prior, and
/// the kitchen's own BarMade order history tunes it: a per-kitchen speed
/// factor and spread, shrunk toward the prior while there are few samples.
struct ReadyTimeModel: Equatable {
    /// Below this prep time there's no cooking: it's a handover at the counter.
    static let grabAndGoMaxMin = 3.0
    /// How many samples it takes before the data counts as much as the prior.
    static let shrinkage = 5.0
    /// A ticket the kitchen took longer than this to close was forgotten, not cooked.
    static let maxBelievableMin = 90.0

    /// Observed / expected kitchen minutes, median over history (1 = as the prior says).
    var kitchenFactor = 1.0
    /// Relative width of the p75 / p90 band.
    var spread = 0.25
    var sampleCount = 0
    /// Mean absolute error of p50 on the history it was fitted on.
    var meanAbsErrorMin: Double?

    static func isRushHour(_ hour: Int) -> Bool { (11...13).contains(hour) || (18...20).contains(hour) }

    /// Prep-time prior for a dish from its recipe: drinks are grab-and-go,
    /// cooked dishes take longer the more goes into them.
    static func prepPrior(for item: BarMadeMenuItem) -> Double {
        let drinkUnits = ["can", "cans", "bottle", "bottles", "glass"]
        let isDrink = !item.ingredients.isEmpty
            && item.ingredients.allSatisfy { drinkUnits.contains($0.unit.lowercased()) }
        if isDrink { return 1.0 }
        return min(25.0, 8.0 + 1.5 * Double(item.ingredients.count))
    }

    /// Kitchen time for an order is set by its slowest item.
    static func prepMinutes(_ preps: [Double]) -> Double { preps.max() ?? 15.0 }

    /// The prior: minutes a kitchen typically needs, before this kitchen's own history.
    static func expectedMinutes(prep: Double, itemCount: Int, busy: Double, when: Date) -> Double {
        let items = Double(max(1, itemCount))
        if prep <= grabAndGoMaxMin {
            return max(0.5, prep + 0.5 * (items - 1))
        }
        let hour = Calendar.current.component(.hour, from: when)
        let weekend = Calendar.current.isDateInWeekend(when)
        return prep + 1.2 * items + 1.8 * busy + (isRushHour(hour) ? 2.0 : 0) + (weekend ? 1.0 : 0)
    }

    /// Minutes from now until ready. `elapsedMin` is how long the kitchen has
    /// had the order already.
    func predict(prep: Double, itemCount: Int, busy: Double, when: Date, elapsedMin: Double = 0) -> ReadyEstimate {
        let q50 = max(1.0, Self.expectedMinutes(prep: prep, itemCount: itemCount, busy: busy, when: when) * kitchenFactor)
        let q75 = q50 * (1 + spread) + 1
        let q90 = q50 * (1 + 2 * spread) + 2
        // Once past the median the kitchen is running late; keep part of the
        // spread instead of claiming the food is ready this instant.
        let r50 = max(q50 - elapsedMin, 1.0)
        let r75 = max(q75 - elapsedMin, r50 + (q75 - q50) * 0.5)
        let r90 = max(q90 - elapsedMin, r75 + (q90 - q75) * 0.5)
        return ReadyEstimate(p50: round1(r50), p75: round1(r75), p90: round1(r90))
    }

    /// Learn this kitchen's speed from how it actually timed past orders.
    static func fit(_ samples: [KitchenSample]) -> ReadyTimeModel {
        let usable = samples.filter { $0.expected > 0 && $0.minutes >= 0.5 && $0.minutes <= maxBelievableMin }
        var m = ReadyTimeModel()
        m.sampleCount = usable.count
        guard !usable.isEmpty else { return m }
        let n = Double(usable.count)
        let ratios = usable.map { $0.minutes / $0.expected }
        let med = median(ratios)
        m.kitchenFactor = (n * med + shrinkage * 1.0) / (n + shrinkage)
        // Robust spread: scaled median absolute deviation, shrunk toward the prior's 0.25.
        let mad = median(ratios.map { abs($0 - med) }) * 1.4826
        m.spread = min(0.6, max(0.15, (n * mad + shrinkage * 0.25) / (n + shrinkage)))
        m.meanAbsErrorMin = round1(usable.map { abs($0.minutes - $0.expected * m.kitchenFactor) }.reduce(0, +) / n)
        return m
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

private func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
