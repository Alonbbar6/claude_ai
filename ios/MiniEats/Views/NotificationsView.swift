import SwiftUI

struct NotificationsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.notifications.isEmpty {
                ContentUnavailableView(
                    "No notifications", systemImage: "bell.slash",
                    description: Text("Order updates will appear here in real time."))
            } else {
                List(store.notifications) { n in
                    NotificationRow(notification: n)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Notifications")
        .refreshable { await store.refreshNotifications() }
        .task {
            store.unreadCount = 0
            await store.refreshNotifications()  // pick up per-channel delivery records
        }
    }
}

private struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: notification.urgent ? "bell.badge.fill" : "bell.fill")
                    .foregroundStyle(notification.urgent ? .orange : .brand)
                Text(notification.title).font(.subheadline.bold())
                Spacer()
                Text(notification.createdAt, style: .relative)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(notification.body).font(.footnote)
            if let deliveries = notification.deliveries, !deliveries.isEmpty {
                HStack(spacing: 6) {
                    ForEach(deliveries, id: \.channel) { d in
                        Text(d.attempts > 1 ? "\(d.channel) \(d.status) ×\(d.attempts)" : "\(d.channel) \(d.status)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(color(for: d.status).opacity(0.18), in: Capsule())
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for status: String) -> Color {
        switch status {
        case "sent": .brand
        case "failed": .red
        case "deferred": .yellow
        default: .gray
        }
    }
}
