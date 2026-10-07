import SwiftUI

struct AccountView: View {
    @Environment(AppStore.self) private var store

    @State private var prefs: NotificationPrefs?
    @State private var server = ""
    @State private var saved = false
    @State private var error: String?

    private let channels: [(id: String, label: String)] = [
        ("push", "Push"), ("sms", "SMS"), ("email", "Email"), ("websocket", "In-app (live)"),
    ]

    var body: some View {
        Form {
            Section("Signed in as") {
                Picker("User", selection: Binding(
                    get: { store.currentUser?.id ?? "" },
                    set: { id in Task { await store.switchUser(id) } })
                ) {
                    ForEach(store.users) { Text($0.name).tag($0.id) }
                }
                if let user = store.currentUser {
                    InfoRow(label: "Phone", value: user.phone)
                    InfoRow(label: "Email", value: user.email)
                }
            }

            if prefs != nil {
                Section {
                    ForEach(channels, id: \.id) { channel in
                        Toggle(channel.label, isOn: channelBinding(channel.id))
                    }
                } header: {
                    Text("Notification channels")
                }

                Section {
                    Stepper("Starts \(hour(prefs!.quietStart))", value: Binding(
                        get: { prefs!.quietStart }, set: { prefs!.quietStart = $0 }), in: 0...23)
                    Stepper("Ends \(hour(prefs!.quietEnd))", value: Binding(
                        get: { prefs!.quietEnd }, set: { prefs!.quietEnd = $0 }), in: 0...23)
                    Toggle("Urgent updates during quiet hours", isOn: Binding(
                        get: { prefs!.allowUrgentInQuietHours }, set: { prefs!.allowUrgentInQuietHours = $0 }))
                } header: {
                    Text("Quiet hours")
                } footer: {
                    Text(prefs!.quietStart == prefs!.quietEnd
                         ? "Off: set different start and end hours to enable."
                         : "Non-urgent updates are held until quiet hours end.")
                }

                Section {
                    Button(saved ? "Saved" : "Save preferences") { Task { await save() } }
                        .disabled(prefs == store.currentUser?.prefs)
                }
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
                Text("Location tracking")
            } footer: {
                Text("Shown on the order map and used to time pickups. Background tracking runs only while a pickup order is in progress.")
            }

            Section {
                TextField("http://127.0.0.1:8000", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Connect") { Task { await store.updateServerURL(server) } }
                HStack {
                    Circle().fill(store.socketConnected ? Color.brand : .red).frame(width: 8, height: 8)
                    Text(store.socketConnected ? "Live updates connected" : "Live updates disconnected")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("On a physical iPhone, use your Mac's LAN IP and run the backend with --host 0.0.0.0.")
            }
        }
        .navigationTitle("Account")
        .onAppear { server = store.serverURL }
        .task(id: store.currentUser) { prefs = store.currentUser?.prefs; saved = false }
        .alert("Couldn't save", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func channelBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { prefs?.channels.contains(id) ?? false },
            set: { on in
                saved = false
                if on {
                    if prefs?.channels.contains(id) == false { prefs?.channels.append(id) }
                } else {
                    prefs?.channels.removeAll { $0 == id }
                }
            })
    }

    private func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    private func save() async {
        guard let prefs else { return }
        do {
            try await store.savePreferences(prefs)
            saved = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
