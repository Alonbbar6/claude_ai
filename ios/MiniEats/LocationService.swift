import CoreLocation
import Observation

/// Customer location for pickup planning. Only runs while a pickup is being
/// quoted or tracked, and only with "While Using" permission.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var authorization: CLAuthorizationStatus

    @ObservationIgnored private let manager = CLLocationManager()

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // Re-plan only on meaningful movement.
        manager.distanceFilter = 75
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Stable key that changes when the user has moved, for `.task(id:)`.
    var movementKey: String {
        guard let c = coordinate else { return "none" }
        return String(format: "%.3f,%.3f", c.latitude, c.longitude)
    }

    func start() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        Task { @MainActor in self.coordinate = c }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Keep the last known fix; the backend falls back to the profile address.
    }
}
