import CoreLocation
import Observation

/// Customer location: shown on the order map and used for pickup planning.
/// Runs with "While Using" from app start. During an active pickup order it
/// can keep running in the background ("Always") so leave-time re-planning
/// continues with the app closed.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var lastFix: Date?
    private(set) var authorization: CLAuthorizationStatus
    private(set) var backgroundTracking = false

    /// Called on every meaningful movement (main actor).
    @ObservationIgnored var onUpdate: ((CLLocationCoordinate2D) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var running = false

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50  // re-plan only on meaningful movement
        manager.pausesLocationUpdatesAutomatically = true
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var hasAlways: Bool { authorization == .authorizedAlways }

    var statusText: String {
        switch authorization {
        case .notDetermined: "Not asked yet"
        case .denied: "Denied in Settings"
        case .restricted: "Restricted"
        case .authorizedWhenInUse: "While using the app"
        case .authorizedAlways: "Always"
        @unknown default: "Unknown"
        }
    }

    /// Stable key that changes when the user has moved, for `.task(id:)`.
    var movementKey: String {
        guard let c = coordinate else { return "none" }
        return String(format: "%.3f,%.3f", c.latitude, c.longitude)
    }

    func start() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        guard !running else { return }
        running = true
        manager.startUpdatingLocation()
    }

    func stop() {
        running = false
        manager.stopUpdatingLocation()
        setBackgroundTracking(false)
    }

    /// Ask to keep tracking in the background (iOS shows the "Always" prompt
    /// once, only after While-Using was granted).
    func requestAlways() {
        if authorization == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
    }

    /// Keep updates flowing while the app is in the background. Only takes
    /// effect with "Always"; harmless otherwise.
    func setBackgroundTracking(_ on: Bool) {
        let enable = on && hasAlways
        manager.allowsBackgroundLocationUpdates = enable
        manager.showsBackgroundLocationIndicator = enable
        manager.pausesLocationUpdatesAutomatically = !enable
        backgroundTracking = enable
        if enable && !running { start() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let c = loc.coordinate
        Task { @MainActor in
            self.coordinate = c
            self.lastFix = loc.timestamp
            self.onUpdate?(c)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isAuthorized {
                if !self.running { self.start() }
                if self.backgroundTracking { self.setBackgroundTracking(true) }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known fix.
    }
}
