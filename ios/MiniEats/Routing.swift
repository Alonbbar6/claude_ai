import CoreLocation
import MapKit

/// Travel time to the restaurant. Apple's directions (traffic-aware for
/// driving, no API key) with a straight-line estimate as the fallback, like
/// the Google-or-haversine routing the old server did.
enum Routing {
    struct Result {
        let estimate: RouteEstimate
        /// The routed path to draw on the map; nil for the fallback.
        let polyline: MKPolyline?
    }

    static let speedKmh: [TravelMode: Double] = [.driving: 19.0, .walking: 4.8]
    static let roadFactor: [TravelMode: Double] = [.driving: 1.3, .walking: 1.2]  // straight line -> route

    static func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, mode: TravelMode) async -> Result {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = mode == .driving ? .automobile : .walking
        request.requestsAlternateRoutes = false
        do {
            let response = try await MKDirections(request: request).calculate()
            if let r = response.routes.first {
                return Result(
                    estimate: RouteEstimate(distanceKm: r.distance / 1000, durationMin: r.expectedTravelTime / 60, source: "apple"),
                    polyline: r.polyline)
            }
        } catch {
            // Offline or no route: fall through to the estimate.
        }
        return fallback(from: origin, to: destination, mode: mode)
    }

    static func fallback(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D, mode: TravelMode) -> Result {
        let km = haversineKm(origin, destination) * roadFactor[mode]!
        let minutes = km / speedKmh[mode]! * 60
        return Result(estimate: RouteEstimate(distanceKm: km, durationMin: minutes, source: "estimate"), polyline: nil)
    }

    static func haversineKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6371.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = (b.latitude - a.latitude) * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(sqrt(h))
    }

    /// The restaurant's address -> coordinate. BarMade publishes no location,
    /// so the app geocodes the address set in Account.
    static func geocode(_ address: String) async -> CLLocationCoordinate2D? {
        guard !address.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? await CLGeocoder().geocodeAddressString(address).first?.location?.coordinate
    }
}
