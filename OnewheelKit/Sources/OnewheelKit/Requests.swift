import Foundation

extension URLSession {
    /// POSTs `body` and returns the status code and response bytes.
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Runs `body` until it returns a value, sleeping `attempt + 1` seconds between
/// tries. Google's endpoints refuse a just-registered device for a moment.
func retrying<T>(
    _ attempts: Int,
    _ what: String,
    log: (String) -> Void,
    _ body: () async throws -> T
) async throws -> T {
    for attempt in 0..<(attempts - 1) {
        do { return try await body() } catch is CancellationError { throw CancellationError() } catch {
            log("\(what) attempt \(attempt + 1): \(error.localizedDescription)")
            try await Task.sleep(for: .seconds(attempt + 1))
        }
    }
    return try await body()
}
