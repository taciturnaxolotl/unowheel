import Foundation
import Network

/// The MCS socket Android devices hold open to `mtalk.google.com` to receive
/// pushes. Single use: log in once, read data messages, close.
actor PushConnection {
    typealias Message = (tag: Tag?, fields: ProtoFields)

    enum Tag: UInt8 {
        case heartbeatPing = 0, heartbeatAck, loginRequest, loginResponse, close
        case iq = 7, dataMessage = 8, streamError = 10
    }

    struct Failure: LocalizedError, Equatable {
        let why: String
        var errorDescription: String? { "Push connection failed: \(why)" }
    }

    static let version: UInt8 = 41

    private let connection: NWConnection
    private var reader: Task<Void, Never>?
    // A mailbox rather than an AsyncStream, so a wait can time out cleanly.
    private var inbox: [Message] = []
    private var failure: Error?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Message?, Error>)?

    private init() {
        connection = NWConnection(host: "mtalk.google.com", port: 5228, using: .tls)
    }

    /// Connects and logs in as `identity`.
    static func open(_ identity: PushIdentity) async throws -> PushConnection {
        let push = PushConnection()
        do {
            try await push.start()
            try await push.send(frame(.loginRequest, loginRequest(identity), first: true))
            guard let reply = try await push.next(timeout: .seconds(15), where: { $0.tag == .loginResponse }) else {
                throw Failure(why: "no login reply")
            }
            if let error = reply.fields.bytes(3) {
                throw Failure(why: (try? ProtoFields(error))?.string(2) ?? error.hexString)
            }
            return push
        } catch {
            await push.close()
            throw error
        }
    }

    static func loginRequest(_ identity: PushIdentity) -> Data {
        var setting = ProtoWriter()
        setting.string(1, "new_vc")
        setting.string(2, "1")
        var login = ProtoWriter()
        login.string(1, "chrome-63.0.3234.0")
        login.string(2, "mcs.android.com")
        login.string(3, String(identity.androidID))
        login.string(4, String(identity.androidID))
        login.string(5, String(identity.securityToken))
        login.string(6, "android-" + String(identity.androidID, radix: 16))
        login.message(8, setting)
        login.varint(12, 0) // adaptive_heartbeat
        login.varint(14, 1) // use_rmq2
        login.varint(16, 2) // auth_service ANDROID_ID
        login.varint(17, 1) // network_type
        return login.data
    }

    static func frame(_ tag: Tag, _ body: Data, first: Bool = false) -> Data {
        var out = first ? Data([version, tag.rawValue]) : Data([tag.rawValue])
        out.append(ProtoWriter.encodeVarint(UInt64(body.count)))
        out.append(body)
        return out
    }

    /// The next data message's key/value pairs, or nil after `timeout`.
    func nextData(timeout: Duration) async throws -> [String: String]? {
        guard let message = try await next(timeout: timeout, where: { $0.tag == .dataMessage }) else { return nil }
        if let persistentID = message.fields.string(9) { try await acknowledge(persistentID) }
        var data: [String: String] = [:]
        for entry in message.fields.all(7) {
            guard let pair = try? ProtoFields(entry), let key = pair.string(1), let value = pair.string(2) else { continue }
            data[key] = value
        }
        return data
    }

    func close() {
        reader?.cancel()
        connection.cancel()
        if let waiter { self.waiter = nil; waiter.continuation.resume(returning: nil) }
    }

    /// Next message passing `filter`, answering heartbeats on the way.
    private func next(timeout: Duration, where filter: (Message) -> Bool) async throws -> Message? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero, let message = try await receive(timeout: remaining) else { return nil }
            switch message.tag {
            case .heartbeatPing: try await send(Self.frame(.heartbeatAck, Data()))
            case .close, .streamError: throw Failure(why: "server closed the stream")
            default: break
            }
            if filter(message) { return message }
        }
    }

    private func receive(timeout: Duration) async throws -> Message? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if let failure { throw failure }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { waiter = (id, $0) }
    }

    private func deliver(_ message: Message) {
        if let waiter { self.waiter = nil; waiter.continuation.resume(returning: message) } else { inbox.append(message) }
    }

    private func fail(_ error: Error) {
        failure = error
        if let waiter { self.waiter = nil; waiter.continuation.resume(throwing: error) }
    }

    private func expire(_ id: UUID) {
        if let waiter, waiter.id == id { self.waiter = nil; waiter.continuation.resume(returning: nil) }
    }

    /// Selective ack (extension 12) so the server doesn't redeliver.
    private func acknowledge(_ persistentID: String) async throws {
        var ids = ProtoWriter()
        ids.string(1, persistentID)
        var ext = ProtoWriter()
        ext.varint(1, 12)
        ext.message(2, ids)
        var iq = ProtoWriter()
        iq.varint(2, 1) // SET
        iq.string(3, "")
        iq.message(7, ext)
        try await send(Self.frame(.iq, iq.data))
    }

    private func start() async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                let outcome: Result<Void, Error>? = switch state {
                case .ready: .success(())
                case .failed(let error), .waiting(let error): .failure(Failure(why: error.localizedDescription))
                case .cancelled: .failure(Failure(why: "cancelled"))
                default: nil
                }
                guard let outcome else { return }
                connection.stateUpdateHandler = nil
                continuation.resume(with: outcome)
            }
            connection.start(queue: DispatchQueue(label: "sh.dunkirk.unowheel.mcs"))
        }
        reader = Task { [weak self] in
            do {
                try await Self.read(from: connection) { [weak self] message in await self?.deliver(message) }
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func send(_ data: Data) async throws {
        let connection = connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(with: error.map { .failure(Failure(why: $0.localizedDescription)) } ?? .success(()))
            })
        }
    }

    /// Frames are `[version] tag varint(size) body`; the version byte only leads the first.
    private static func read(from connection: NWConnection, deliver: @Sendable (Message) async -> Void) async throws {
        var buffer = Data()
        var first = true
        func need(_ count: Int) async throws {
            while buffer.count < count {
                let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                        if let error { continuation.resume(throwing: Failure(why: error.localizedDescription)) }
                        else if let data, !data.isEmpty { continuation.resume(returning: data) }
                        else if complete { continuation.resume(throwing: Failure(why: "connection closed")) }
                        else { continuation.resume(returning: Data()) }
                    }
                }
                buffer.append(chunk)
            }
        }
        while !Task.isCancelled {
            let header = first ? 2 : 1
            try await need(header + 1)
            let tag = buffer[buffer.startIndex + header - 1]
            var index = header, size = 0, shift = 0
            while true {
                try await need(index + 1)
                let byte = buffer[buffer.startIndex + index]
                index += 1
                size |= Int(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            try await need(index + size)
            let start = buffer.startIndex + index
            let body = buffer.subdata(in: start..<(start + size))
            buffer.removeFirst(index + size)
            first = false
            await deliver((Tag(rawValue: tag), try ProtoFields(body)))
        }
    }
}
