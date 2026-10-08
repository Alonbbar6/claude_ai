import SwiftUI

enum Format {
    static func minutes(_ m: Double) -> String { "\(max(1, Int(m.rounded()))) min" }
    static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
    /// Stock quantities: up to 2 decimals, no trailing zeros ("1.2", "14").
    static func qty(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
    /// "~45 min", "~3 h", "~2 d".
    static func duration(hours h: Double) -> String {
        if h < 1 { return "~\(max(1, Int((h * 60).rounded()))) min" }
        if h < 48 { return "~\(Int(h.rounded())) h" }
        return "~\(Int((h / 24).rounded())) d"
    }
}

// BarMade palette (getbarmade.com): gold on black, lightened for daytime
// ordering like the web app's tailwind.config.ts.
extension Color {
    static let gold = Color(red: 0xA5 / 255, green: 0x7F / 255, blue: 0x00 / 255)
    static let goldText = Color(red: 0x8A / 255, green: 0x6A / 255, blue: 0x00 / 255)
    static let goldTint = Color(red: 0xF5 / 255, green: 0xED / 255, blue: 0xD6 / 255)
    static let night = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)
    static let cream = Color(red: 0xFA / 255, green: 0xF7 / 255, blue: 0xF0 / 255)
    static let ink = Color(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255)
    static let inkSoft = Color(red: 0x5C / 255, green: 0x5C / 255, blue: 0x5C / 255)
    static let line = Color(red: 0xE8 / 255, green: 0xE2 / 255, blue: 0xD4 / 255)
    static let fresh = Color(red: 0x2F / 255, green: 0x7D / 255, blue: 0x4F / 255)
    static let freshTint = Color(red: 0xE3 / 255, green: 0xF2 / 255, blue: 0xE8 / 255)
    static let warn = Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x1A / 255)
    static let warnTint = Color(red: 0xFB / 255, green: 0xEA / 255, blue: 0xDF / 255)
    /// Accent for tab bars, links and "ok" states.
    static let brand = gold
}

// MARK: - Order vocabulary (shared by the customer tracker and the kitchen)

func orderStatusTitle(_ status: String) -> String {
    switch status {
    case "RECEIVED": "Received"
    case "PREPARING": "Preparing"
    case "READY": "Ready"
    case "COMPLETED": "Picked up"
    case "CANCELLED": "Cancelled"
    default: status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

func orderStatusColor(_ status: String) -> Color {
    switch status {
    case "RECEIVED": .orange
    case "PREPARING": .blue
    case "READY": .purple
    case "CANCELLED": .red
    default: .fresh
    }
}

/// "To go" / "For here · table 7".
func fulfillmentLabel(_ fulfillment: String?, table: String?) -> String? {
    switch fulfillment {
    case "to_go": "To go"
    case "for_here": table.map { "For here · table \($0)" } ?? "For here"
    default: nil
    }
}

/// Where an order came from, for the kitchen's ticket.
func orderSourceLabel(_ source: String?) -> String? {
    switch source {
    case "barmade-web": "Web"
    case barMadeAppSource: "iPhone app"
    case nil, "": nil
    default: source
    }
}

// MARK: - Building blocks

/// Small rounded label (the web app's `.chip`).
struct Chip: View {
    let text: String
    var background: Color = .cream
    var foreground: Color = .inkSoft

    var body: some View {
        Text(text)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }
}

/// Tinted status label: "Sold out", "Low", "Preparing".
struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Stat: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Full-width gold button (the web app's `.btn-gold`).
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.night)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal)
            .background(Color.gold.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Quantity stepper: − n +
struct QuantityStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...20

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: { Image(systemName: "minus") }
                .disabled(value <= range.lowerBound)
            Text("\(value)").monospacedDigit().frame(minWidth: 32).font(.headline)
            Button { value = min(range.upperBound, value + 1) } label: { Image(systemName: "plus") }
                .disabled(value >= range.upperBound)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.cream, in: Capsule())
        .overlay(Capsule().stroke(Color.line))
    }
}

/// "Ordered via BarMade" mark, as on the web order page.
struct ViaBarMade: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "fork.knife.circle.fill").foregroundStyle(Color.gold)
            Text("Ordered via BarMade").font(.caption.weight(.bold)).foregroundStyle(Color.goldText)
        }
    }
}
