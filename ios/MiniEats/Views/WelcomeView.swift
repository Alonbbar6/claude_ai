import SwiftUI

/// Name-only sign in, like the web app's Welcome: the kitchen calls your
/// order by name, nothing else is asked.
struct WelcomeView: View {
    @Environment(CustomerStore.self) private var store
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [.night.opacity(0.75), .night], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            // Scrolls when the keyboard is up instead of squeezing the copy.
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("BarMade").font(.title2.weight(.black)).foregroundStyle(Color.gold)
                    Spacer()
                }
                Text("🍕").font(.system(size: 64)).padding(.top, 48)
                Text("Skip the line.\nOrder ahead.")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Text("Order from your phone and pick it up when it's ready — or have it served at your table.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)

                VStack(alignment: .leading, spacing: 10) {
                    Text("What's your name?").font(.subheadline.bold()).foregroundStyle(Color.ink)
                    TextField("Your first name", text: $name)
                        .foregroundStyle(Color.ink)  // the card is light even though the screen is dark
                        .tint(.gold)
                        .textContentType(.givenName)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(submit)
                        .padding(14)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Color.gold : Color.line))
                        .accessibilityIdentifier("name-field")
                    Button("Start ordering →", action: submit)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .padding(.top, 4)
                    Text("We only ask for your name, so the kitchen can call your order.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                .padding(.top, 28)
            }
            .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private func submit() {
        store.setName(name)
    }
}
