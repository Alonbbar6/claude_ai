import Foundation

struct APIError: LocalizedError {
    let message: String
    /// HTTP status when the server answered (409 = the kitchen can't make it).
    var status: Int? = nil
    var errorDescription: String? { message }
}

/// Backends emit ISO-8601 with any precision ("…18.434223Z", "+00:00", or
/// just seconds). Foundation's parser only accepts millisecond fractions,
/// so trim first.
enum APIDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        let trimmed = string.replacingOccurrences(
            of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return withFraction.date(from: trimmed) ?? plain.date(from: trimmed)
    }
}

/// A value from Info.plist that xcodegen fills from a build setting. Empty
/// or unexpanded ("$(...)") means "not set".
func infoPlistURL(_ key: String) -> String? {
    guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String,
          !s.isEmpty, !s.hasPrefix("$(") else { return nil }
    return s
}
