import Foundation

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thin async wrapper over the FastAPI backend.
struct APIClient {
    let baseURL: URL

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send("GET", path, query: query, body: Optional<Empty>.none)
    }

    func post<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send("POST", path, query: query, body: Optional<Empty>.none)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send("POST", path, body: body)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await send("PUT", path, body: body)
    }

    func delete(_ path: String) async throws {
        _ = try await raw("DELETE", path, query: [:], body: Optional<Empty>.none)
    }

    private struct Empty: Encodable {}
    private struct ErrorBody: Decodable { let detail: String }

    private func send<T: Decodable, B: Encodable>(
        _ method: String, _ path: String, query: [String: String] = [:], body: B?
    ) async throws -> T {
        let data = try await raw(method, path, query: query, body: body)
        return try JSONDecoder.api.decode(T.self, from: data)
    }

    private func raw<B: Encodable>(
        _ method: String, _ path: String, query: [String: String], body: B?
    ) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw APIError(message: "Bad server URL")
        }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError(message: "Bad server URL") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        // Lets the app pass straight through ngrok's free-tier browser warning page.
        request.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning")
        if let body {
            request.httpBody = try JSONEncoder.api.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // FastAPI errors look like {"detail": "..."}; validation errors use a list.
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw APIError(message: detail ?? "Server returned \(status)")
        }
        return data
    }
}

extension JSONDecoder {
    static let api: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = APIDate.parse(string) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
            }
            return date
        }
        return decoder
    }()
}

extension JSONEncoder {
    static let api: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

/// Python emits ISO-8601 with microseconds ("…18.434223Z" or "+00:00").
/// Foundation's parser only accepts millisecond precision, so trim first.
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

/// A saved server address that can't be right on a physical device: 127.0.0.1
/// or localhost there is the phone itself. Falls back to the built-in default.
func usableServerURL(saved: String?, fallback: String) -> String {
    guard let saved, !saved.isEmpty else { return fallback }
    #if targetEnvironment(simulator)
    return saved
    #else
    let host = URL(string: saved)?.host?.lowercased() ?? ""
    let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
    return loopback ? fallback : saved
    #endif
}

