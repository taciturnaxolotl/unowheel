import Foundation

/// Fetches a board's unlock response from Future Motion the way the official
/// Android app does: POST the challenge with a push token, then read the
/// `boardActivation` push. See docs/protocol.md, "Fetching the response".
public enum Activation {
    public enum Failure: LocalizedError, Equatable {
        case badBoardName(String)
        case server(String)
        case noResponse
        case implausible(String)

        public var errorDescription: String? {
            switch self {
            case .badBoardName(let name): "\(name) doesn't look like a Onewheel serial."
            case .server(let why): "Future Motion refused the request: \(why)"
            case .noResponse: "Future Motion didn't send an unlock code."
            case .implausible(let hex): "Future Motion sent a code that doesn't fit this board: \(hex)"
            }
        }
    }

    /// Cloudflare in front of app-api rejects unfamiliar user agents (error 1010).
    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 14; Pixel 7 Build/AP2A.240805.005)"
    /// Covers Google's occasional ~8 s hold; a push not here by then was dropped, so ask again.
    static let askAgainAfter: Duration = .seconds(10)
    /// How long `boardActivationFailed`, seen with just-registered tokens, takes to clear.
    static let rejectedRetryAfter: Duration = .seconds(3)

    /// `ow292642` -> 292642. The server keys boards by the numeric serial.
    public static func boardID(from name: String) -> Int? {
        var digits = name.lowercased()
        if digits.hasPrefix("ow") { digits.removeFirst(2) }
        return Int(digits)
    }

    /// The 16 nonce bytes as upper-case hex (Guava's base16).
    public static func requestKey(for challenge: Challenge) -> String {
        challenge.nonce.map { String(format: "%02X", $0) }.joined()
    }

    public static func activationURL(board: Int) -> URL {
        URL(string: "https://app-api.onewheel.com/api/v1/android/boards/\(board)/activation")!
    }

    struct Request: Encodable, Equatable {
        let key: String
        let token: String
        var userId = 0
    }

    struct Reply: Decodable {
        struct Problem: Decodable { let code: String }
        let error: Problem?
    }

    /// Asks Future Motion for this board's response. A saved identity is tried
    /// first; if its push never arrives, a new one is registered and returned.
    public static func fetchResponse(
        board name: String,
        challenge: Challenge,
        identity saved: PushIdentity? = nil,
        timeout: Duration = .seconds(30),
        session: URLSession = .shared,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> (response: Data, identity: PushIdentity) {
        guard let board = boardID(from: name) else { throw Failure.badBoardName(name) }
        if let saved {
            do {
                return (try await fetch(board: board, challenge: challenge, identity: saved, timeout: timeout, session: session, log: log), saved)
            } catch let error where error is PushConnection.Failure || error as? Failure == .noResponse {
                log("saved push identity didn't work (\(error.localizedDescription)), registering a new one")
            }
        }
        let fresh = try await PushIdentity.register(session: session, log: log)
        return (try await fetch(board: board, challenge: challenge, identity: fresh, timeout: timeout, session: session, log: log), fresh)
    }

    private static func fetch(
        board: Int, challenge: Challenge, identity: PushIdentity,
        timeout: Duration, session: URLSession, log: @escaping @Sendable (String) -> Void
    ) async throws -> Data {
        let push = try await retrying(5, "push login", log: log) { try await PushConnection.open(identity) }
        defer { Task { await push.close() } }
        log("push connection ready")

        // Asking again on the same token recovers a push Google dropped; a second copy is harmless.
        let request = Request(key: requestKey(for: challenge), token: identity.token)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            log("asking for board \(board), key \(request.key)")
            let window = try await ask(board: board, request, session: session) ? askAgainAfter : rejectedRetryAfter
            if let response = try await response(from: push, board: board, challenge: challenge, within: min(window, deadline - ContinuousClock.now)) {
                return response
            }
        }
        throw Failure.noResponse
    }

    /// POSTs the challenge. False means `boardActivationFailed`, which clears on its own.
    private static func ask(board: Int, _ request: Request, session: URLSession) async throws -> Bool {
        let (status, data) = try await session.post(
            activationURL(board: board),
            body: try JSONEncoder().encode(request),
            headers: ["Content-Type": "application/json; charset=utf-8", "User-Agent": userAgent]
        )
        let problem = (try? JSONDecoder().decode(Reply.self, from: data))?.error?.code
        if status == 200, problem == nil { return true }
        if problem == "boardActivationFailed" { return false }
        throw Failure.server("\(status) \(problem ?? String(decoding: data.prefix(200), as: UTF8.self))")
    }

    private static func response(from push: PushConnection, board: Int, challenge: Challenge, within window: Duration) async throws -> Data? {
        let deadline = ContinuousClock.now + window
        while let data = try await push.nextData(timeout: deadline - ContinuousClock.now) {
            guard data["type"] == "boardActivation", data["owId"].flatMap(Int.init) == board else { continue }
            guard let hex = data["key"], let response = Handshake.parseHex(hex),
                  Handshake.isPlausibleResponse(response, for: challenge)
            else { throw Failure.implausible(data["key"] ?? "") }
            return response
        }
        return nil
    }
}
