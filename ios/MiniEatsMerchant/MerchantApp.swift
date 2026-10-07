import SwiftUI

@main
struct MerchantApp: App {
    @State private var store = MerchantStore()

    var body: some Scene {
        WindowGroup {
            MerchantRootView()
                .environment(store)
                .task { await store.start() }
        }
    }
}

struct MerchantRootView: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        if store.restaurant == nil {
            NavigationStack { RestaurantPickerView() }
        } else {
            TabView {
                NavigationStack { MenuCatalogView() }
                    .tabItem { Label("Menu", systemImage: "menucard.fill") }
                NavigationStack { InventoryView() }
                    .tabItem { Label("Inventory", systemImage: "shippingbox.fill") }
                    .badge(store.problemCount)
                NavigationStack { AlertsView() }
                    .tabItem { Label("Alerts", systemImage: "bell.fill") }
                    .badge(store.unreadAlerts)
                NavigationStack { MerchantSettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }
            .tint(.brand)
            // Customer orders move stock; keep the numbers live.
            .task(id: store.restaurantId) {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    await store.reload()
                }
            }
        }
    }
}

struct RestaurantPickerView: View {
    @Environment(MerchantStore.self) private var store
    @State private var server = ""

    var body: some View {
        List {
            if let error = store.loadError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                    TextField(MerchantStore.defaultServer, text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Connect") { Task { await store.updateServerURL(server) } }
                } header: {
                    Text("Server")
                }
            }
            Section("Choose your restaurant") {
                ForEach(store.restaurants) { r in
                    Button {
                        Task { await store.select(r.id) }
                    } label: {
                        HStack(spacing: 14) {
                            CuisineIcon(cuisine: r.cuisine, size: 44)
                            VStack(alignment: .leading) {
                                Text(r.name).font(.headline).foregroundStyle(.primary)
                                Text(r.cuisine).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Eats Merchant")
        .refreshable { await store.start() }
        .onAppear { server = store.serverURL }
    }
}

struct MerchantSettingsView: View {
    @Environment(MerchantStore.self) private var store
    @State private var server = ""

    var body: some View {
        Form {
            Section("Restaurant") {
                if let r = store.restaurant {
                    HStack(spacing: 12) {
                        CuisineIcon(cuisine: r.cuisine, size: 40)
                        Text(r.name).font(.headline)
                    }
                }
                Button("Switch restaurant") { Task { await store.select(nil) } }
            }
            Section("Server") {
                TextField(MerchantStore.defaultServer, text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect") { Task { await store.updateServerURL(server) } }
                if let error = store.loadError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear { server = store.serverURL }
    }
}

struct AlertsView: View {
    @Environment(MerchantStore.self) private var store

    var body: some View {
        Group {
            if store.alerts.isEmpty {
                ContentUnavailableView(
                    "No alerts", systemImage: "checkmark.seal",
                    description: Text("You'll see low-stock and sold-out alerts here."))
            } else {
                List(store.alerts) { alert in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: alert.kind == "out" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(alert.kind == "out" ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(alert.message).font(.subheadline)
                            Text(alert.at, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Alerts")
        .refreshable { await store.reload() }
        .onAppear { store.markAlertsSeen() }
        .onChange(of: store.alerts) { store.markAlertsSeen() }
    }
}
