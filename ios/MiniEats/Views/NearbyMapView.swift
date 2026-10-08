import MapKit
import SwiftUI

/// You and the restaurant on one map: the routed path between you, how long
/// the trip takes and when food would be ready if you ordered now. Tap the
/// restaurant to order.
struct NearbyMapView: View {
    @Environment(CustomerStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
            Annotation(store.restaurant.name, coordinate: store.restaurantCoordinate) {
                Button {
                    store.selectedTab = .menu
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "fork.knife")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.night)
                            .frame(width: 40, height: 40)
                            .background(Color.gold, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2))
                            .shadow(radius: 3)
                        if store.menu.isEmpty == false {
                            Text(chipText)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("restaurant-pin")
            }
            if let line = store.tripLine {
                MapPolyline(line).stroke(Color.gold.opacity(0.8), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else if let me = store.location.coordinate {
                MapPolyline(coordinates: [me, store.restaurantCoordinate])
                    .stroke(Color.gold.opacity(0.6), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle("Near you")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("Getting there", selection: Binding(
                    get: { store.mode }, set: { m in Task { await store.setMode(m) } })
                ) {
                    ForEach(TravelMode.allCases, id: \.self) { Image(systemName: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
            }
        }
        .overlay(alignment: .bottom) { tripCard }
        .onAppear {
            store.location.start()
            fit()
            Task { await store.refreshTrip() }
        }
        // The first GPS fix usually lands after the map shows: re-route and re-frame from here.
        .task(id: store.location.movementKey) {
            if store.location.coordinate != nil { await store.refreshTrip() }
            fit()
        }
    }

    /// "ready ~12 min · 8 min drive"
    private var chipText: String {
        var parts = ["ready ~\(Format.minutes(store.menuReadyMinutes))"]
        if let t = store.trip { parts.append("\(Format.minutes(t.durationMin)) \(store.mode.verb)") }
        return parts.joined(separator: " · ")
    }

    private var tripCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.location.isDenied ? "location.slash" : store.location.coordinate == nil ? "location" : "location.fill")
                    .foregroundStyle(Color.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.restaurant.name).font(.headline)
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button {
                    store.selectedTab = .menu
                } label: {
                    Text("Order now →").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Button {
                    if let url = directionsURL { openURL(url) }
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gold)
                .controlSize(.large)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 12)
        .accessibilityIdentifier("trip-card")
    }

    private var statusText: String {
        if store.location.isDenied { return "Location is off. Turn it on in Settings to see yourself here." }
        guard store.location.coordinate != nil else { return "Finding your location…" }
        guard let t = store.trip else { return "Routing your trip…" }
        let ready = store.menuReadyMinutes
        return "\(Format.km(t.distanceKm)) · \(Format.minutes(t.durationMin)) \(store.mode.verb) · food ready in ~\(Format.minutes(ready)) if you order now"
    }

    private var directionsURL: URL? {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(store.restaurantCoordinate.latitude),\(store.restaurantCoordinate.longitude)"),
            URLQueryItem(name: "dirflg", value: store.mode == .driving ? "d" : "w"),
            URLQueryItem(name: "q", value: store.restaurant.name),
        ]
        return c?.url
    }

    /// Frame you and the restaurant; without a fix, the restaurant's neighbourhood.
    private func fit() {
        var points = [store.restaurantCoordinate]
        if let me = store.location.coordinate { points.append(me) }
        let lats = points.map(\.latitude), lngs = points.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(), let minLng = lngs.min(), let maxLng = lngs.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.02),
                                    longitudeDelta: max((maxLng - minLng) * 1.6, 0.02))
        withAnimation { camera = .region(MKCoordinateRegion(center: center, span: span)) }
    }
}
