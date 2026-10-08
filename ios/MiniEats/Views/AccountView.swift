import SwiftUI

struct AccountView: View {
    @Environment(CustomerStore.self) private var store
    @State private var name = ""
    @State private var server = ""
    @State private var web = ""
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
        }
        .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { store.signOut() }
        } message: {
            Text("Your name, cart and order history are removed from this phone.")
        }
    }
}
