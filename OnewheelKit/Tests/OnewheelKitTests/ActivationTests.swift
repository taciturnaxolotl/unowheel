import Foundation
import Testing
@testable import OnewheelKit

@Suite struct ActivationTests {
    @Test func boardIDFromName() {
        #expect(Activation.boardID(from: "ow292642") == 292642)
        #expect(Activation.boardID(from: "OW292642") == 292642)
        #expect(Activation.boardID(from: "292642") == 292642)
        #expect(Activation.boardID(from: "Onewheel") == nil)
    }

    @Test func requestKeyIsUpperCaseNonce() throws {
        let challenge = try #require(Challenge(hydrusChallenge))
        #expect(Activation.requestKey(for: challenge) == "E366F5ACAABC75876952677D0CCB012D")
        #expect(Activation.activationURL(board: 292642).absoluteString
            == "https://app-api.onewheel.com/api/v1/android/boards/292642/activation")
    }

    @Test func activationBodyMatchesTheAndroidApp() throws {
        let body = try JSONEncoder().encode(Activation.Request(key: "AB", token: "t"))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["key"] as? String == "AB")
        #expect(json["token"] as? String == "t")
        #expect(json["userId"] as? Int == 0)
    }

    @Test func installationIDShape() {
        for _ in 0..<50 {
            let fid = PushIdentity.newInstallationID()
            #expect(fid.count == 22)
            #expect("cdef".contains(fid.first!))
            #expect(fid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test func protobufRoundTrip() throws {
        #expect(ProtoWriter.encodeVarint(300) == Data([0xAC, 0x02]))
        var inner = ProtoWriter()
        inner.string(1, "new_vc")
        var outer = ProtoWriter()
        outer.varint(2, 5_120_177_912_914_979_810)
        outer.message(8, inner)
        outer.string(8, "x")
        let fields = try ProtoFields(outer.data)
        #expect(fields.integer(2) == 5_120_177_912_914_979_810)
        #expect(fields.all(8).count == 2)
        #expect(try ProtoFields(fields.all(8)[0]).string(1) == "new_vc")
    }

    @Test func checkinResponseFixed64() throws {
        // android_id (7) and security_token (8) come back as fixed64.
        var data = Data([7 << 3 | 1])
        withUnsafeBytes(of: UInt64(0x1122_3344_5566_7788).littleEndian) { data.append(contentsOf: $0) }
        data.append(8 << 3 | 1)
        withUnsafeBytes(of: UInt64(42).littleEndian) { data.append(contentsOf: $0) }
        let fields = try ProtoFields(data)
        #expect(fields.integer(7) == 0x1122_3344_5566_7788)
        #expect(fields.integer(8) == 42)
    }

    @Test func checkinRequestIsAChromeDevice() throws {
        let request = try ProtoFields(PushIdentity.checkinRequest())
        #expect(request.integer(14) == 3)
        let checkin = try ProtoFields(try #require(request.bytes(4)))
        #expect(checkin.integer(12) == 3)
        #expect(try ProtoFields(try #require(checkin.bytes(13))).string(2) == "63.0.3234.0")
    }

    @Test func serverReplyErrors() throws {
        let ok = try JSONDecoder().decode(Activation.Reply.self, from: Data(#"{"data":null,"error":null}"#.utf8))
        #expect(ok.error == nil)
        let refused = try JSONDecoder().decode(Activation.Reply.self, from: Data(#"{"error":{"code":"boardActivationFailed","message":"x"}}"#.utf8))
        #expect(refused.error?.code == "boardActivationFailed")
    }

    @Test func retryingStopsAtFirstSuccess() async throws {
        var calls = 0
        let value = try await retrying(3, "test", log: { _ in }) { () async throws -> Int in
            calls += 1
            return 7
        }
        #expect(value == 7 && calls == 1)
    }

    @Test func mcsLoginFrame() throws {
        let creds = PushIdentity(androidID: 0xABC, securityToken: 7, installationID: "f", token: "t")
        let frame = PushConnection.frame(.loginRequest, PushConnection.loginRequest(creds), first: true)
        #expect(frame.prefix(2) == Data([41, 2]))
        let body = try ProtoFields(frame.dropFirst(2 + 1 + (frame[2] & 0x80 == 0 ? 0 : 1)))
        #expect(body.string(3) == "2748")
        #expect(body.string(5) == "7")
        #expect(body.string(6) == "android-abc")
        #expect(body.integer(16) == 2)
    }

    /// Hits Future Motion and Google for real. `ONEWHEEL_LIVE=1 swift test --filter live`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ONEWHEEL_LIVE"] == "1"))
    func liveFetchMatchesCapturedResponse() async throws {
        let challenge = try #require(Challenge(hydrusChallenge))
        let (response, identity) = try await Activation.fetchResponse(board: "ow292642", challenge: challenge) { print(Date.now.timeIntervalSince1970, $0) }
        #expect(response == hydrusResponse)
        #expect(!identity.token.isEmpty)

        // The app's usual case: a saved identity.
        let start = ContinuousClock.now
        let again = try await Activation.fetchResponse(board: "ow292642", challenge: challenge, identity: identity) { print("saved:", $0) }
        #expect(again.response == hydrusResponse)
        #expect(again.identity == identity)
        print("saved identity took", ContinuousClock.now - start)
    }
}
