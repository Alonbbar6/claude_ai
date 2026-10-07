import MapKit
import SwiftUI

/// Live map for an order: the restaurant (with its address), the customer's
/// home or current position, and the courier moving along the route for
/// deliveries. Positions refresh with the order (every poll / push).
struct TrackingMap: View {
    let order: Order
    let restaurant: Restaurant
    let customer: AppUser?
    @Environment(AppStore.self) private var store
    @State private var camera: MapCameraPosition = .automatic

    private var restaurantPoint: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: restaurant.lat, longitude: restaurant.lng)
    }

    /// Delivery: the saved home address. Pickup: where the phone is now,
    /// falling back to the location sent with the order.
    private var customerPoint: CLLocationCoordinate2D? {
        if order.isPickup {
            if let c = store.location.coordinate { return c }
            if let lat = order.pickupLat, let lng = order.pickupLng {
                return CLLocationCoordinate2D(latitude: lat, longitude: lng)
            }
            return nil
        }
        if let lat = order.deliveryLat, let lng = order.deliveryLng {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        guard let customer else { return nil }
        return CLLocationCoordinate2D(latitude: customer.lat, longitude: customer.lng)
    }

    private var courierPoint: CLLocationCoordinate2D? {
        guard let c = order.courierLocation else { return nil }
        return CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng)
    }

    /// Straight-line legs; a production app would draw the routed polyline.
    private var legs: [[CLLocationCoordinate2D]] {
        guard let home = customerPoint else { return [] }
        if order.isPickup { return [[home, restaurantPoint]] }
        var out: [[CLLocationCoordinate2D]] = [[restaurantPoint, home]]
        if let courier = courierPoint, order.status == .courierDispatched {
            out.append([courier, restaurantPoint])
        }
        return out
    }

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            Annotation(restaurant.name, coordinate: restaurantPoint) {
                MapPin(system: "fork.knife", color: .brand)
            }
            // Pickups show the live blue dot instead of a static "You" pin.
            if !order.isPickup, let home = customerPoint {
                Annotation("Deliver here", coordinate: home) {
                    MapPin(system: "mappin", color: .blue)
                }
            }
            if let courier = courierPoint, !order.status.isClosed {
                Annotation(order.dispatch?.courierName ?? "Courier", coordinate: courier) {
                    MapPin(system: "car.fill", color: .orange)
                }
            }
            ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                MapPolyline(coordinates: leg)
                    .stroke(Color.brand.opacity(0.6), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottomLeading) {
            if !restaurant.address.isNilOrEmpty {
                Label(restaurant.address ?? "", systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .onChange(of: order.status) { fit() }
        .onChange(of: order.courierLocation) { fit() }
        .onAppear(perform: fit)
        .accessibilityIdentifier("tracking-map")
    }

    /// Frame every point of interest with some breathing room.
    private func fit() {
        var points = [restaurantPoint]
        if let c = customerPoint { points.append(c) }
        if let c = courierPoint { points.append(c) }
        let lats = points.map(\.latitude), lngs = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.01),
                                    longitudeDelta: max((maxLng - minLng) * 1.6, 0.01))
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}

private struct MapPin: View {
    let system: String
    let color: Color

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .padding(7)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 3)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
