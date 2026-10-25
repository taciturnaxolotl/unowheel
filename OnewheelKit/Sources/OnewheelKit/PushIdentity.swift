import Foundation

/// A device registered for push as Future Motion's Android app. One works for
/// every board and every request, so register once and keep it.
public struct PushIdentity: Codable, Equatable, Sendable {
    public var androidID: UInt64
    public var securityToken: UInt64
    public var installationID: String
    public var token: String

    public enum Failure: LocalizedError, Equatable {
        case registration(String)

        public var errorDescription: String? {
            switch self {
            case .registration(let why): "Push registration failed: \(why)"
            }
        }
    }

    // From the official app's resources and signing certificate (2.6.85).
    static let package = "com.rideonewheel.onewheel"
    static let certificateSHA1 = "1233D799B5012097EB4D88010B0E0028F64CBB30"
    static let apiKey = "AIzaSyCn975YtjSbauFmaSziujB8w5j2jk1FGjI"
    static let project = "onewheel-production"
    static let appID = "1:690240897008:android:4f5b4fdb4fe5f138"
    static let sender = "690240897008"

    /// Firebase installation, GCM checkin, then `register3`. See docs/protocol.md.
    public static func register(session: URLSession = .shared, log: (String) -> Void = { _ in }) async throws -> PushIdentity {
        let (fid, fisToken) = try await install(session: session)
        log("firebase installation \(fid)")
        let (androidID, securityToken) = try await checkin(session: session)
        log("checked in as \(androidID)")
        let token = try await retrying(6, "register", log: log) {
            try await registerToken(androidID: androidID, securityToken: securityToken, fid: fid, fisToken: fisToken, session: session)
        }
        log("push token \(token.prefix(24))…")
        return PushIdentity(androidID: androidID, securityToken: securityToken, installationID: fid, token: token)
    }

    /// 17 random bytes, top nibble 0111, base64url, 22 characters.
    static func newInstallationID() -> String {
        var bytes = (0..<17).map { _ in UInt8.random(in: 0...255) }
        bytes[0] = 0x70 | (bytes[0] & 0x0F)
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return String(b64.prefix(22))
    }

    private struct Installation: Decodable {
        struct Token: Decodable { let token: String }
        let fid: String
        let authToken: Token
    }

    private static func install(session: URLSession) async throws -> (fid: String, token: String) {
        let body = try JSONEncoder().encode([
            "fid": newInstallationID(), "appId": appID, "authVersion": "FIS_v2", "sdkVersion": "a:17.2.0",
        ])
        let (status, data) = try await session.post(
            URL(string: "https://firebaseinstallations.googleapis.com/v1/projects/\(project)/installations")!,
            body: body,
            headers: [
                "Content-Type": "application/json", "x-goog-api-key": apiKey,
                "X-Android-Package": package, "X-Android-Cert": certificateSHA1,
            ]
        )
        guard status == 200, let installation = try? JSONDecoder().decode(Installation.self, from: data) else {
            throw Failure.registration("installation \(status) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return (installation.fid, installation.authToken.token)
    }

    static func checkinRequest() -> Data {
        var chrome = ProtoWriter()
        chrome.varint(1, 3) // PLATFORM_LINUX
        chrome.string(2, "63.0.3234.0")
        chrome.varint(3, 1) // CHANNEL_STABLE
        var checkin = ProtoWriter()
        checkin.varint(12, 3) // DEVICE_CHROME_BROWSER
        checkin.message(13, chrome)
        var request = ProtoWriter()
        request.message(4, checkin)
        request.varint(14, 3)
        request.varint(22, 0)
        return request.data
    }

    private static func checkin(session: URLSession) async throws -> (UInt64, UInt64) {
        let (status, data) = try await session.post(
            URL(string: "https://android.clients.google.com/checkin")!,
            body: checkinRequest(),
            headers: ["Content-Type": "application/x-protobuf"]
        )
        guard status == 200, let fields = try? ProtoFields(data),
              let id = fields.integer(7), let token = fields.integer(8)
        else { throw Failure.registration("checkin \(status)") }
        return (id, token)
    }

    private static func registerToken(
        androidID: UInt64, securityToken: UInt64, fid: String, fisToken: String, session: URLSession
    ) async throws -> String {
        let form: [(String, String)] = [
            ("app", package), ("cert", certificateSHA1.lowercased()), ("device", String(androidID)),
            ("sender", sender), ("X-subtype", sender), ("X-scope", "*"),
            ("X-gmp_app_id", appID), ("X-appid", fid), ("X-Goog-Firebase-Installations-Auth", fisToken),
            ("X-cliv", "fcm-23.4.1"), ("app_ver", "268501"), ("gcm_ver", "241517038"),
        ]
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let body = form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }.joined(separator: "&")
        let (_, data) = try await session.post(
            URL(string: "https://android.clients.google.com/c2dm/register3")!,
            body: Data(body.utf8),
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Authorization": "AidLogin \(androidID):\(securityToken)",
            ]
        )
        let reply = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reply.hasPrefix("token=") else { throw Failure.registration(reply) }
        return String(reply.dropFirst(6))
    }
}
