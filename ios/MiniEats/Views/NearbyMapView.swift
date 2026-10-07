import MapKit
import SwiftUI

/// You and every restaurant on one map, with the delivery time and distance
/// from where you are. Tap a pin to open its menu.
struct NearbyMapView: View {
    @Environment(AppStore.self) private var store
    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: Restaurant?

    var body: some View {
        Map(position: $camera, selection: $selected) {
            UserAnnotation()
            ForEach(store.restaurants) { r in
                Annotation(r.name, coordinate: CLLocationCoordinate2D(latitude: r.lat, longitude: r.lng)) {
                    VStack(spacing: 2) {
                        CuisineIcon(cuisine: r.cuisine, size: 34)
                        if let p = store.pickupQuotes[r.id] {
                            Text("ready ~\(Format.minutes(p.readyInMin)) · \(Format.minutes(p.tripMin)) \(p.verb)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .onTapGesture { selected = r }
                }
                .tag(r)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Near you")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { MenuView(restaurant: $0) }
        .overlay(alignment: .bottom) { statusBar }
        .onAppear { store.location.start(); fit() }
        .task(id: store.location.movementKey) {
            if store.location.coordinate != nil { await store.loadQuotes() }
            fit()
        }
    }

    private var statusBar: some View {
        Group {
            if store.location.isDenied {
                Label("Location is off. Turn it on in Settings to see yourself here.", systemImage: "location.slash")
            } else if store.location.coordinate == nil {
                Label("Finding your location…", systemImage: "location")
            } else {
                Label("Distances and times are from your current location", systemImage: "location.fill")
            }
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    /// Frame you and the restaurants; without a fix, just the restaurants.
    private func fit() {
        var points = store.restaurants.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        if let me = store.location.coordinate { points.append(me) }
        guard !points.isEmpty else { return }
        let lats = points.map(\.latitude), lngs = points.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lngs.min()! + lngs.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((lats.max()! - lats.min()!) * 1.5, 0.02),
                                    longitudeDelta: max((lngs.max()! - lngs.min()!) * 1.5, 0.02))
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}
