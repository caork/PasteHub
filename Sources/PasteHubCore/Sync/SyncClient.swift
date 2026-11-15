import Foundation

public enum SyncClientError: Error, LocalizedError, Equatable {
    case unauthorized
    case http(status: Int, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "服务器不认可这个同步密钥"
        case let .http(status, message): "服务器返回 \(status)：\(message)"
        case .invalidResponse: "服务器响应格式不正确"
        }
    }
}

/// Thin HTTP client for the relay API (docs/sync-protocol.md).
struct SyncClient: Sendable {
    let baseURL: URL
    let token: String
    let session: URLSession

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncClientError.invalidResponse }
        switch http.statusCode {
        case 200 ..< 300:
            return data
        case 401:
            throw SyncClientError.unauthorized
        default:
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SyncClientError.http(status: http.statusCode, message: message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try Self.decoder.decode(type, from: data) } catch { throw SyncClientError.invalidResponse }
    }

    func space() async throws -> SpaceInfo {
        try decode(SpaceInfo.self, await send(request("v1/space")))
    }

    func push(_ ops: [WireOp]) async throws -> PushResponse {
        var req = request("v1/ops", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Self.encoder.encode(PushRequest(ops: ops))
        return try decode(PushResponse.self, await send(req))
    }

    func pull(after: Int64, limit: Int = 500) async throws -> PullResponse {
        let req = request("v1/ops", query: [
            URLQueryItem(name: "after", value: String(after)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try decode(PullResponse.self, await send(req))
    }

    func putBlob(id: String, data: Data) async throws {
        var req = request("v1/blobs/\(id)", method: "PUT")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        _ = try await send(req.withBody(data))
    }

    func getBlob(id: String) async throws -> Data {
        var req = request("v1/blobs/\(id)")
        req.timeoutInterval = 300
        return try await send(req)
    }

    func streamTask() -> URLSessionWebSocketTask {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/stream"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var req = URLRequest(url: components.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: req)
    }
}

private extension URLRequest {
    func withBody(_ data: Data) -> URLRequest {
        var copy = self
        copy.httpBody = data
        return copy
    }
}
