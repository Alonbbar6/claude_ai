import SwiftUI

struct AccountView: View {
    @Environment(CustomerStore.self) private var store
    @State private var name = ""
    @State private var server = ""
    @State private var web = ""
    @State private var address = ""
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section("Your name") {
                TextField("Your first name", text: $name).textContentType(.givenName)
                Button("Save name") { store.setName(name) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == store.name)
            }

            Section {
                TextField(CustomerStore.defaultServer, text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") { Task { await store.updateServerURL(server) } }
                HStack {
                    Circle().fill(store.loadError == nil && store.loadedAt != nil ? Color.fresh : Color.red).frame(width: 8, height: 8)
                    Text(store.loadError ?? (store.loadedAt.map { "Connected · menu as of \(Format.time($0))" } ?? "Connecting…"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Kitchen (BarMade API)")
            } footer: {
                Text("Menu, stock and orders come from the BarMade backend that the web app and the kitchen's app share.")
            }

            Section {
                TextField("https://…up.railway.app", text: $web)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") { Task { await store.updateWebURL(web) } }
                if store.web != nil {
                    Label("Photos and descriptions loaded", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Color.fresh)
                }
            } header: {
                Text("Web app (optional)")
            } footer: {
                Text("The customer web app's address. When set, dishes show the same photos, descriptions and categories as on the web.")
            }

            Section {
                InfoRow(label: "Permission", value: store.location.statusText)
                if let c = store.location.coordinate {
                    InfoRow(label: "Last fix", value: String(format: "%.4f, %.4f", c.latitude, c.longitude))
                }
                InfoRow(label: "Background", value: store.location.backgroundTracking ? "On (pickup in progress)" : "Off")
                if store.location.isDenied {
                    Link("Turn on in Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                } else if store.location.authorization == .notDetermined {
                    Button("Allow location") { store.location.start() }
                } else if !store.location.hasAlways {
                    Button("Allow background tracking") { store.location.requestAlways() }
                }
            } header: {
                Text("Location")
            } footer: {
                Text("Shown on the order map and used to time your pickup. Background tracking runs only while an order is in the kitchen.")
            }

            Section {
                Picker("Restaurant", selection: Binding(
                    get: { store.restaurant },
                    set: { r in Task { await store.selectRestaurant(r); address = store.restaurantAddress } })
                ) {
                    ForEach(CustomerStore.restaurants) { r in
                        Text(r.isQA ? "\(r.name) (QA)" : r.name).tag(r)
                    }
                }
                TextField(store.restaurant.address, text: $address)
                Button("Save address") { Task { await store.updateRestaurantAddress(address) } }
                    .disabled(address == store.restaurantAddress)
                InfoRow(label: "Pinned at", value: String(format: "%.4f, %.4f", store.restaurantCoordinate.latitude, store.restaurantCoordinate.longitude))
            } header: {
                Text("Restaurant")
            } footer: {
                Text(store.restaurant.isQA
                     ? "QA venue for testing at Miami Dade College Wolfson Campus. Orders still go to the real BarMade kitchen."
                     : "BarMade doesn't publish the kitchen's location, so trips are planned to this address.")
            }

            Section {
                ForEach(TravelMode.allCases, id: \.self) { m in
                    Stepper(value: Binding(
                        get: { store.arrivalOverhead[m] ?? PickupPlanner.arrivalOverheadMin[m]! },
                        set: { v in Task { await store.setArrivalOverhead(v, for: m) } }),
                        in: 0...15, step: 0.5
                    ) {
                        InfoRow(label: m == .driving ? "Driving: park and walk in" : "Walking: walk in",
                                value: String(format: "%g min", store.arrivalOverhead[m] ?? 0))
                    }
                    .accessibilityIdentifier("overhead-\(m.rawValue)")
                }
            } header: {
                Text("Pickup timing")
            } footer: {
                Text("Leave time = food ready time − (travel time + this buffer). At 0 you leave exactly when the kitchen's time minus your travel time says; the default keeps a couple of minutes for parking.")
            }

            Section {
                InfoRow(label: "Orders learned from", value: "\(store.model.sampleCount)")
                InfoRow(label: "Kitchen pace vs. typical", value: String(format: "%.0f%%", store.model.kitchenFactor * 100))
                InfoRow(label: "Tickets open now", value: "\(Int(store.kitchenBusy))")
            } header: {
                Text("Ready-time model")
            } footer: {
                Text("Runs on this phone, tuned to how the kitchen timed its past orders (RECEIVED → READY).")
            }

            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            } footer: {
                Text("Classroom demo · synthetic data")
            }
        }
        .navigationTitle("Account")
        .onAppear {
            name = store.name ?? ""
            server = store.serverURL
            web = store.webURL
            address = store.restaurantAddress
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { store.signOut() }
        } message: {
            Text("Your name, cart and order history are removed from this phone.")
        }
    }
}
