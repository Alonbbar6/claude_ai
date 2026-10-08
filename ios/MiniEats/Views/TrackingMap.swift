import MapKit
import SwiftUI

/// Live map for a pickup: the restaurant, where the phone is now, and the
/// routed path between them. Re-frames as the customer moves.
struct TrackingMap: View {
    let order: BarMadeOrder
    @Environment(CustomerStore.self) private var store
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            Annotation(store.restaurant.name, coordinate: store.restaurantCoordinate) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(Color.gold, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 3)
            }
            if let line = store.routes[order.id] {
                MapPolyline(line).stroke(Color.gold.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else if let me = store.location.coordinate {
                MapPolyline(coordinates: [me, store.restaurantCoordinate])
                    .stroke(Color.gold.opacity(0.6), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(alignment: .bottomLeading) {
            Label(store.restaurantAddress, systemImage: "mappin.and.ellipse")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
        .onAppear(perform: fit)
        .onChange(of: store.location.movementKey) { fit() }
        .onChange(of: store.routes[order.id] == nil) { fit() }
        .accessibilityIdentifier("tracking-map")
    }

    /// Frame the restaurant and the customer with some breathing room.
    private func fit() {
        var points = [store.restaurantCoordinate]
        if let me = store.location.coordinate { points.append(me) }
        let lats = points.map(\.latitude), lngs = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.01),
                                    longitudeDelta: max((maxLng - minLng) * 1.6, 0.01))
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}
