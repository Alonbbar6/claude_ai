import SwiftUI

enum Format {
    static func minutes(_ m: Double) -> String { "\(max(1, Int(m.rounded()))) min" }
    static func money(_ v: Double) -> String { v.formatted(.currency(code: "USD")) }
    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
    static func km(_ v: Double) -> String { String(format: "%.1f km", v) }
    /// Stock quantities: up to 2 decimals, no trailing zeros ("1.2", "14").
    static func qty(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2))) }
    /// "~45 min", "~3 h", "~2 d".
    static func duration(hours h: Double) -> String {
        if h < 1 { return "~\(max(1, Int((h * 60).rounded()))) min" }
        if h < 48 { return "~\(Int(h.rounded())) h" }
        return "~\(Int((h / 24).rounded())) d"
    }
}

extension Color {
    static let brand = Color(red: 0.02, green: 0.76, blue: 0.40)
}

struct RiskBadge: View {
    let risk: Double

    private var label: String {
        risk >= 0.6 ? "High delay risk" : risk >= 0.3 ? "Some delay risk" : "On time"
    }
    private var color: Color {
        risk >= 0.6 ? .red : risk >= 0.3 ? .orange : .brand
    }

    var body: some View {
        Text("\(label) · \(Int((risk * 100).rounded()))%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct CuisineIcon: View {
    let cuisine: String
    var size: CGFloat = 52

    private var symbol: String {
        switch cuisine.lowercased() {
        case "japanese": "fish.fill"
        case "italian": "flame.fill"
        case "american": "takeoutbag.and.cup.and.straw.fill"
        default: "fork.knife"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.brand.gradient, in: RoundedRectangle(cornerRadius: size * 0.25))
    }
}

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal)
            .background(Color.black.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct NotificationBanner: View {
    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notification.urgent ? "bell.badge.fill" : "bell.fill")
                .foregroundStyle(notification.urgent ? .orange : .brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title).font(.subheadline.bold())
                Text(notification.body).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal)
    }
}
