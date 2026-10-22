@preconcurrency import CoreBluetooth
import Foundation
import Observation
import OnewheelKit

struct DiscoveredBoard: Identifiable, Hashable {
    let id: UUID
    let name: String
    var rssi: Int
    var known: Bool

    var displayName: String { KnownBoards.displayName(for: name) }
}

enum BoardError: LocalizedError {
    case notConnected
    case missingCharacteristic(Characteristic)
    case timeout(String)
    case bluetooth(String)
    case rejected

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to a board."
        case .missingCharacteristic(let c): "Missing characteristic \(c.rawValue)."
        case .timeout(let what): "Timed out waiting for \(what)."
        case .bluetooth(let message): message
        case .rejected: "The board rejected this unlock code."
        }
    }
}

@MainActor
@Observable
final class BoardConnection: NSObject {
    enum Phase: Equatable {
        case bluetoothOff
        case idle
        case scanning
        /// A connection request is pending; iOS connects as soon as the board
        /// is on and in range, even with UnoWheel in the background.
        case waiting(String)
        case connecting(String)
        case handshaking
        case needsResponse
        case unlocked
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var discovered: [DiscoveredBoard] = []

    var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    /// Boards to offer in the list. The one we're already waiting for is
    /// shown in its own banner, so leave it out here.
    var nearby: [DiscoveredBoard] {
        guard case .waiting = phase, let waitingID = peripheral?.identifier else { return discovered }
        return discovered.filter { $0.id != waitingID }
    }
    private(set) var boardName: String?
    private(set) var nickname: String?

    /// What to call the board in the UI: your nickname, else its serial.
    var displayName: String? { nickname ?? boardName }
    private(set) var telemetry = Telemetry()
    private(set) var challenge: Challenge?
    private(set) var log: [String] = []
    private(set) var range = RangeEstimator()
    private(set) var unlockedAt: Date?
    private(set) var chargeSession: ChargeSession?
    private(set) var voltage = PackVoltageEstimator()

    /// Reported pack voltage, or worked out from power and charge counters
    /// on firmware that stopped reporting it.
    var packVolts: Double? { telemetry.batteryVoltage ?? voltage.volts }
    var isToppingOff: Bool { ChargeSession.isToppingOff(percent: telemetry.batteryPercent, watts: telemetry.chargingWatts) }

    var rangeKm: Double? { range.rangeKm(for: shown) }

    /// Stats saved from the last time this board was connected.
    private(set) var cached: Telemetry?
    private(set) var lastSeenAt: Date?

    var isLive: Bool { phase == .unlocked }
    /// Live values when connected, otherwise the last known ones.
    var shown: Telemetry { isLive ? telemetry : (cached ?? telemetry) }
    var hasData: Bool { isLive || cached != nil }



    var isConnected: Bool {
        switch phase {
        case .connecting, .handshaking, .needsResponse, .unlocked: true
        default: false
        }
    }

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [Characteristic: CBCharacteristic] = [:]
    @ObservationIgnored private var assembler = ChallengeAssembler()
    @ObservationIgnored private let challengeWaiters = Waiters<Challenge>()
    @ObservationIgnored private let discoveryWaiters = Waiters<Void>()
    @ObservationIgnored private let readWaiters = WaiterTable<Data>()
    @ObservationIgnored private let writeWaiters = WaiterTable<Void>()
    @ObservationIgnored private let notifyWaiters = WaiterTable<Void>()
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    /// Other known boards with a pending connect. Whichever board turns on
    /// first gets picked up, so a second board needs no manual pairing step.
    @ObservationIgnored private var pendingOthers: [CBPeripheral] = []
    /// Set when you pick a board by hand: wait for that one only until it
    /// connects, so the other board doesn't win the race.
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private let mirror = RideMirror()
    let rides = RideStore()
    @ObservationIgnored private lazy var recorder: RideRecorder = {
        let recorder = RideRecorder(store: rides)
        recorder.log = { [weak self] line in self?.record(line) }
        return recorder
    }()
    private(set) var isRecording = false

    func endRide(save: Bool) {
        recorder.end(save: save)
        isRecording = recorder.isRecording
    }
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var lastTick = Date.now
    @ObservationIgnored private var lastRangeSave = Date.now
    /// Set when you skip unlocking a board, so it isn't grabbed straight back.
    /// Cleared after the app has been away for a while.
    @ObservationIgnored private var autoConnectPaused = false
    @ObservationIgnored private var isDemo = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundedAt: Date?

    override init() {
        super.init()
        if let name = KnownBoards.lastConnected {
            boardName = name
            nickname = KnownBoards.nickname(for: name)
            loadRange(for: name)
            loadCache(for: name)
        }
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "sh.dunkirk.unowheel.central",
        ])
        mirror.log = { [weak self] line in self?.record(line) }
        LightsBridge.handler = { [weak self] on in await self?.applyLights(on) }
        mirrorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastTick)
        lastTick = now
        recorder.update(board: boardName, telemetry: telemetry, live: isLive, now: now)
        if isRecording != recorder.isRecording { isRecording = recorder.isRecording }
        guard isConnected else { return }
        if phase == .unlocked { voltage.record(telemetry, at: now) }
        if phase == .unlocked, telemetry.isCharging, let percent = telemetry.batteryPercent {
            if chargeSession == nil { chargeSession = ChargeSession() }
            chargeSession?.record(percent: percent, watts: telemetry.chargingWatts)
        } else if !telemetry.isCharging {
            chargeSession = nil
        }
        if phase == .unlocked, !telemetry.isCharging {
            range.record(telemetry, seconds: elapsed)
            if now.timeIntervalSince(lastRangeSave) > 30 { saveRange() }
        }
        if phase == .unlocked, now.timeIntervalSince(lastSeenAt ?? .distantPast) > 15 { saveCache() }
        syncMirror()
    }

    private func syncMirror() {
        mirror.sync(name: displayName, telemetry: telemetry, unlocked: phase == .unlocked,
                    rangeKm: rangeKm, rangeLearned: range.isLearned, startedAt: unlockedAt,
                    charge: chargeSession, ride: recorder.current)
    }

    private func loadRange(for board: String) {
        let data = UserDefaults.standard.data(forKey: "range.\(board.lowercased())")
        range = data.flatMap { try? JSONDecoder().decode(RangeEstimator.self, from: $0) } ?? RangeEstimator()
    }

    private func saveRange() {
        lastRangeSave = .now
        guard let boardName, let data = try? JSONEncoder().encode(range) else { return }
        UserDefaults.standard.set(data, forKey: "range.\(boardName.lowercased())")
    }

    private struct CachedBoard: Codable {
        var telemetry: Telemetry
        var seenAt: Date
    }

    private func loadCache(for board: String) {
        let data = UserDefaults.standard.data(forKey: "telemetry.\(board.lowercased())")
        let entry = data.flatMap { try? JSONDecoder().decode(CachedBoard.self, from: $0) }
        cached = entry?.telemetry
        lastSeenAt = entry?.seenAt
    }

    /// Keeps the slow-moving stats; drops what only means something live.
    private func saveCache() {
        guard let boardName, telemetry.looksUnlocked else { return }
        var snapshot = telemetry
        snapshot.rpm = nil
        snapshot.powerWatts = nil
        snapshot.currentAmps = nil
        snapshot.statusError = nil
        snapshot.pitch = nil
        snapshot.roll = nil
        snapshot.yaw = nil
        cached = snapshot
        lastSeenAt = .now
        guard let data = try? JSONEncoder().encode(CachedBoard(telemetry: snapshot, seenAt: .now)) else { return }
        UserDefaults.standard.set(data, forKey: "telemetry.\(boardName.lowercased())")
    }

    // MARK: - Boards

    var knownBoards: [String] { KnownBoards.names }

    /// Makes another known board the current one and waits for it.
    func switchTo(_ name: String) {
        guard name.lowercased() != boardName?.lowercased() else { return }
        retryTask?.cancel()
        saveRange()
        dropPeripheral()
        mirror.finish()
        KnownBoards.lastConnected = name.lowercased()
        boardName = name.lowercased()
        nickname = KnownBoards.nickname(for: name)
        telemetry = Telemetry()
        loadRange(for: name)
        loadCache(for: name)
        autoConnectPaused = false
        pinned = true
        phase = .idle
        armAutoConnect()
    }

    func forget(_ name: String) {
        let isCurrent = name.lowercased() == boardName?.lowercased()
        if isCurrent {
            retryTask?.cancel()
            dropPeripheral()
            mirror.finish()
        }
        KnownBoards.forget(name)
        guard isCurrent else { return }
        if let next = KnownBoards.lastConnected {
            boardName = nil
            switchTo(next)
        } else {
            boardName = nil
            nickname = nil
            cached = nil
            lastSeenAt = nil
            telemetry = Telemetry()
            phase = .idle
            startScan()
        }
    }

    #if DEBUG
    /// Fake unlocked board for screenshots: launch with `-demo`.
    func loadDemo() {
        isDemo = true
        boardName = "ow292642"
        nickname = "Turbo"
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.firmwareRevision, data: WireValue.encode(5208))
        t.apply(.batteryPercent, data: WireValue.encode(54))
        t.apply(.rideMode, data: WireValue.encode(6))
        t.apply(.rpm, data: WireValue.encode(310))
        t.apply(.temperature, data: Data([23, 22]))
        t.apply(.batteryTemperature, data: Data([0, 22]))
        t.apply(.batteryLow5, data: WireValue.encode(184))
        t.apply(.tripOdometer, data: WireValue.encode(2100))
        t.apply(.lifetimeOdometer, data: WireValue.encode(412))
        t.apply(.pitch, data: WireValue.encode(1776))
        for word: UInt16 in [0x2008, 0xc006, 0xf000, 0xf101, 0xf264, 0xd000, 0xd113, 0xd29c, 0xd3d4] {
            t.apply(.lastErrorCode, data: WireValue.encode(word))
        }
        if CommandLine.arguments.contains("-charging") {
            t.apply(.statusError, data: WireValue.encode(0x2004))
            t.apply(.batteryLow5, data: WireValue.encode(UInt16(bitPattern: -170)))
            t.apply(.batteryPercent, data: WireValue.encode(46))
            var session = ChargeSession(startedAt: .now.addingTimeInterval(-900))
            for i in 0...30 {
                session.record(percent: 22 + Int(Double(i) * 0.8), watts: 170, at: .now.addingTimeInterval(Double(i - 30) * 30))
            }
            chargeSession = session
        }
        if CommandLine.arguments.contains("-rides"), rides.rides.isEmpty {
            // A loop around a park, faster on the straights.
            let start = Date.now.addingTimeInterval(-3 * 3600)
            var points: [RidePoint] = []
            for i in 0..<900 {
                let a = Double(i) / 900 * 2 * .pi
                let speed = 12 + 10 * abs(sin(a * 2))
                points.append(RidePoint(time: start.addingTimeInterval(Double(i) * 2),
                                        latitude: 40.1265 + 0.004 * sin(a), longitude: -82.9290 + 0.006 * cos(a),
                                        speedKPH: speed, batteryPercent: 88 - i / 30))
            }
            rides.save(Ride(board: "ow292642", points: points, odometerKm: 3.2))
            var second = points.prefix(300).map { $0 }
            for j in second.indices { second[j].time = second[j].time.addingTimeInterval(-86400) }
            rides.save(Ride(board: "ow292642", points: second, odometerKm: 1.1))
        }
        if CommandLine.arguments.contains("-offline") {
            t.rpm = nil
            t.powerWatts = nil
            t.statusError = nil
            cached = t
            lastSeenAt = .now.addingTimeInterval(-25 * 60)
            telemetry = Telemetry()
            phase = .idle
            return
        }
        telemetry = t
        unlockedAt = .now.addingTimeInterval(-600)
        phase = .unlocked
    }
    #endif

    // MARK: - Auto-connect

    /// Asks iOS to connect to the last board whenever it shows up. The request
    /// never times out, and survives the app being suspended or relaunched.
    func armAutoConnect() {
        retryTask?.cancel()
        retryTask = nil
        guard !autoConnectPaused, central.state == .poweredOn, peripheral == nil,
              let name = KnownBoards.lastConnected, let id = KnownBoards.all[name],
              let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        wait(for: target, name: name)
        pendOthers(except: name)
    }

    private func pendOthers(except name: String) {
        guard !pinned else { return }
        let others = KnownBoards.all.filter { $0.key != name.lowercased() }.map(\.value)
        pendingOthers = central.retrievePeripherals(withIdentifiers: others)
        for other in pendingOthers {
            other.delegate = self
            central.connect(other)
        }
    }

    private func cancelOthers() {
        for other in pendingOthers { central.cancelPeripheralConnection(other) }
        pendingOthers = []
    }

    /// A pending connect never times out: iOS completes it whenever the board
    /// starts advertising, even with the app suspended.
    private func wait(for target: CBPeripheral, name: String) {
        prepare(target, name: name)
        phase = .waiting(name)
        record("waiting for \(name)")
        central.connect(target)
    }

    /// Tries again shortly, so a board that drops out mid-handshake doesn't
    /// leave the app stuck or hammering the radio.
    private func scheduleRetry(after seconds: Double = 2) {
        guard !autoConnectPaused else { return }
        retryTask?.cancel()
        if let name = KnownBoards.lastConnected { phase = .waiting(name) }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.armAutoConnect()
        }
    }

    /// "Not now" on the unlock sheet: let go of this board for a while.
    func skipBoard() {
        retryTask?.cancel()
        cancelOthers()
        dropPeripheral()
        mirror.finish()
        autoConnectPaused = true
        phase = .idle
    }

    /// Forgets the current board before cancelling, so the disconnect
    /// callback for it is ignored rather than mistaken for a new drop.
    private func dropPeripheral() {
        saveCache()
        cancelOthers()
        teardown()
        guard let old = peripheral else { return }
        peripheral = nil
        central.cancelPeripheralConnection(old)
    }

    /// Call when the app comes to the foreground. Skipping a board pauses
    /// auto-connect for this visit only.
    func appBecameActive() {
        defer { backgroundedAt = nil }
        if boardName != nil { recorder.requestPermissionIfNeeded() }
        guard let since = backgroundedAt, Date.now.timeIntervalSince(since) > 120, autoConnectPaused else { return }
        autoConnectPaused = false
        if peripheral == nil { armAutoConnect() }
    }

    func appEnteredBackground() {
        backgroundedAt = .now
    }

    private func prepare(_ target: CBPeripheral, name: String) {
        boardName = name
        nickname = KnownBoards.nickname(for: name)
        telemetry = Telemetry()
        challenge = nil
        characteristics = [:]
        assembler.reset()
        unlockedAt = nil
        chargeSession = nil
        voltage = PackVoltageEstimator()
        loadRange(for: name)
        loadCache(for: name)
        peripheral = target
        target.delegate = self
    }

    // MARK: - Scanning

    func startScan() {
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        let known = KnownBoards.all
        for peripheral in central.retrievePeripherals(withIdentifiers: Array(known.values)) {
            if let name = known.first(where: { $0.value == peripheral.identifier })?.key {
                upsert(DiscoveredBoard(id: peripheral.identifier, name: name, rssi: 0, known: true))
            }
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        // Scanning is a side activity; don't overwrite a live or pending connection.
        switch phase {
        case .idle, .failed, .bluetoothOff: phase = .scanning
        default: break
        }
    }

    func stopScan() {
        central.stopScan()
        if phase == .scanning { phase = .idle }
    }

    private func upsert(_ board: DiscoveredBoard) {
        if let index = discovered.firstIndex(where: { $0.id == board.id }) {
            discovered[index].rssi = board.rssi == 0 ? discovered[index].rssi : board.rssi
        } else {
            discovered.append(board)
            discovered.sort { ($0.known ? 0 : 1, -$0.rssi) < ($1.known ? 0 : 1, -$1.rssi) }
        }
    }

    // MARK: - Connecting

    func connect(_ board: DiscoveredBoard) {
        guard let target = central.retrievePeripherals(withIdentifiers: [board.id]).first else {
            phase = .failed("Lost \(board.name). Scan again.")
            return
        }
        retryTask?.cancel()
        if peripheral?.identifier != target.identifier {
            dropPeripheral()
            mirror.finish()
        }
        autoConnectPaused = false
        pinned = true
        KnownBoards.lastConnected = board.name
        // A remembered board that hasn't been heard from may be off or out
        // of range; wait for it rather than spin on "Connecting".
        if board.rssi == 0 {
            wait(for: target, name: board.name)
            return
        }
        central.stopScan()
        prepare(target, name: board.name)
        phase = .connecting(board.name)
        record("connecting to \(board.name)")
        central.connect(target)
    }

    private func teardown() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        failAllWaiters(BoardError.notConnected)
    }

    // MARK: - Session

    private func runSession() async {
        do {
            try await discoverAll()
            let hw = try await read(.hardwareRevision)
            let fw = try await read(.firmwareRevision)
            telemetry.apply(.hardwareRevision, data: hw)
            telemetry.apply(.firmwareRevision, data: fw)
            telemetry.apply(.rideMode, data: try await read(.rideMode))
            let firmware = telemetry.firmwareRevision ?? 0
            record("hw \(telemetry.hardwareRevision ?? 0) fw \(firmware) \(telemetry.model.displayName)")

            if let name = boardName, let id = peripheral?.identifier {
                KnownBoards.remember(name, id: id)
                KnownBoards.lastConnected = name
            }

            if telemetry.looksUnlocked {
                record("board already unlocked")
                try await finishUnlock()
                return
            }

            phase = .handshaking
            let strategy = Handshake.strategy(firmware: firmware)
            if strategy == .none {
                try await finishUnlock()
                return
            }

            // A saved code works without asking for a challenge first (the
            // official app does this too), which saves a round trip.
            if strategy == .serverIssued, let name = boardName, let saved = UnlockStore.response(for: name, challenge: nil) {
                record("using saved code")
                if (try? await submit(saved, remember: false)) != nil { return }
                record("saved code rejected, asking for a challenge")
            }

            let challenge = try await requestChallenge(firmware: fw)
            self.challenge = challenge
            record("challenge \(challenge.bytes.spacedHex)")

            switch strategy {
            case .gemini:
                try await submit(Handshake.geminiResponse(for: challenge), remember: false)
            case .serverIssued:
                if let name = boardName, let saved = UnlockStore.response(for: name, challenge: challenge) {
                    record("using saved response")
                    try await submit(saved, remember: false)
                } else {
                    phase = .needsResponse
                }
            case .none:
                break
            }
        } catch is CancellationError {
        } catch {
            record("session failed: \(error.localizedDescription)")
            dropPeripheral()
            mirror.finish()
            scheduleRetry()
        }
    }

    /// Writes an unlock response and checks that the board starts serving data.
    func submit(_ response: Data, remember: Bool = true) async throws {
        record("response \(response.spacedHex)")
        phase = .handshaking
        do {
            try await write(.uartWrite, response, withResponse: true)
            // The board usually unlocks within one read; give it about a second.
            for attempt in 0..<8 {
                telemetry.apply(.batteryPercent, data: try await read(.batteryPercent))
                if telemetry.looksUnlocked { break }
                if attempt < 7 { try await Task.sleep(for: .milliseconds(120)) }
            }
            guard telemetry.looksUnlocked else {
                phase = .needsResponse
                throw BoardError.rejected
            }
            if remember, let name = boardName {
                UnlockStore.save(response, challenge: challenge, for: name)
                record("saved response for \(name)")
            }
            try await finishUnlock()
        } catch BoardError.rejected {
            record("board rejected response")
            throw BoardError.rejected
        }
    }

    func submitPasted(_ text: String) async throws {
        guard let data = Handshake.parseHex(text), data.count == Handshake.frameLength else {
            throw BoardError.bluetooth("An unlock code is 40 hex characters.")
        }
        try await submit(data)
    }

    private func requestChallenge(firmware fw: Data) async throws -> Challenge {
        try await setNotify(.uartRead, true)
        assembler.reset()
        try await write(.firmwareRevision, fw, withResponse: true)
        let challenge = try await challengeWaiters.wait(timeout: 5, what: "the unlock challenge") {}
        try? await setNotify(.uartRead, false)
        return challenge
    }

    private func finishUnlock() async throws {
        phase = .unlocked
        unlockedAt = .now
        record("unlocked")
        startKeepAlive()
        // GATT requests go out one at a time, so ask for what the dashboard
        // shows first, all at once, then the rest.
        let first: [Characteristic] = [.batteryPercent, .rpm, .rideMode, .batteryLow5, .lightingMode, .statusError]
        let rest = Characteristic.telemetry.filter { !first.contains($0) }
        await subscribe(first)
        await subscribe(rest)
    }

    private func subscribe(_ list: [Characteristic]) async {
        let tasks = list.filter { characteristics[$0] != nil }.map { characteristic in
            Task { @MainActor [weak self] in
                try? await self?.setNotify(characteristic, true)
                if let data = try? await self?.read(characteristic) {
                    self?.telemetry.apply(characteristic, data: data)
                }
            }
        }
        for task in tasks { await task.value }
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        let keepAlive = Handshake.keepAlive(firmware: telemetry.firmwareRevision ?? 0)
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(keepAlive.interval))
                guard let self, !Task.isCancelled else { return }
                try? await self.write(keepAlive.characteristic, keepAlive.payload, withResponse: true)
            }
        }
    }

    // MARK: - Controls

    func setRideMode(_ mode: RideMode) {
        guard (telemetry.speedKPH ?? 0) < 1 else { return }
        Task {
            do {
                try await write(.rideMode, WireValue.encode(mode.value), withResponse: true)
                telemetry.apply(.rideMode, data: try await read(.rideMode))
            } catch { record("ride mode: \(error.localizedDescription)") }
        }
    }

    func setLights(_ on: Bool) {
        Task { await applyLights(on) }
    }

    /// Writes the lights, reads them back, and pushes the result to the Live
    /// Activity at once instead of waiting for the next tick.
    func applyLights(_ on: Bool) async {
        do {
            try await write(.lightingMode, WireValue.encode(on ? 1 : 0), withResponse: true)
            telemetry.apply(.lightingMode, data: try await read(.lightingMode))
        } catch {
            record("lights: \(error.localizedDescription)")
        }
        syncMirror()
    }

    func rename(to newName: String) {
        guard let boardName else { return }
        KnownBoards.setNickname(newName, for: boardName)
        nickname = KnownBoards.nickname(for: boardName)
        record("renamed to \(displayName ?? boardName)")
    }

    func forgetResponse() {
        guard let boardName else { return }
        UnlockStore.remove(for: boardName)
        record("forgot saved response for \(boardName)")
    }

    // MARK: - GATT plumbing

    private func discoverAll() async throws {
        guard let peripheral else { throw BoardError.notConnected }
        try await discoveryWaiters.wait(timeout: 15, what: "service discovery") {
            peripheral.discoverServices([CBUUID(string: Characteristic.serviceUUIDString)])
        }
    }

    func read(_ characteristic: Characteristic) async throws -> Data {
        let (peripheral, cb) = try target(characteristic)
        return try await readWaiters[characteristic.rawValue].wait(timeout: 5, what: "a read of \(characteristic.rawValue)") {
            peripheral.readValue(for: cb)
        }
    }

    func write(_ characteristic: Characteristic, _ data: Data, withResponse: Bool) async throws {
        let (peripheral, cb) = try target(characteristic)
        guard withResponse else {
            peripheral.writeValue(data, for: cb, type: .withoutResponse)
            return
        }
        try await writeWaiters[characteristic.rawValue].wait(timeout: 5, what: "a write to \(characteristic.rawValue)") {
            peripheral.writeValue(data, for: cb, type: .withResponse)
        }
    }

    private func setNotify(_ characteristic: Characteristic, _ enabled: Bool) async throws {
        let (peripheral, cb) = try target(characteristic)
        guard cb.properties.contains(.notify) || cb.properties.contains(.indicate) else { return }
        try await notifyWaiters[characteristic.rawValue].wait(timeout: 5, what: "notifications on \(characteristic.rawValue)") {
            peripheral.setNotifyValue(enabled, for: cb)
        }
    }

    private func target(_ characteristic: Characteristic) throws -> (CBPeripheral, CBCharacteristic) {
        guard let peripheral, peripheral.state == .connected else { throw BoardError.notConnected }
        guard let cb = characteristics[characteristic] else { throw BoardError.missingCharacteristic(characteristic) }
        return (peripheral, cb)
    }

    private func failAllWaiters(_ error: Error) {
        challengeWaiters.failAll(error)
        discoveryWaiters.failAll(error)
        readWaiters.failAll(error)
        writeWaiters.failAll(error)
        notifyWaiters.failAll(error)
    }

    private func fail(_ error: Error) {
        record("error: \(error.localizedDescription)")
        if case BoardError.rejected = error { return }
        phase = .failed(error.localizedDescription)
    }

    private func record(_ line: String) {
        let stamp = Date.now.formatted(date: .omitted, time: .standard)
        log.append("\(stamp) \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

// MARK: - CBCentralManagerDelegate

extension BoardConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !isDemo else { return }
        switch central.state {
        case .poweredOn:
            if let restored = peripheral {
                // State restoration hands us a board before the radio is ready.
                if restored.state == .connected, sessionTask == nil {
                    phase = .connecting(boardName ?? "board")
                    sessionTask = Task { await runSession() }
                } else if restored.state != .connected {
                    central.connect(restored)
                    if let name = boardName { pendOthers(except: name) }
                }
            } else {
                armAutoConnect()
            }
            if !isConnected { startScan() }
        case .poweredOff, .unauthorized, .unsupported:
            retryTask?.cancel()
            teardown()
            pendingOthers = []
            peripheral = nil
            mirror.finish()
            phase = .bluetoothOff
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isOnewheel = name.lowercased().hasPrefix("ow")
            || services.contains(CBUUID(string: Characteristic.serviceUUIDString))
        guard isOnewheel, !name.isEmpty else { return }
        let known = KnownBoards.all[name.lowercased()] != nil
        upsert(DiscoveredBoard(id: peripheral.identifier, name: name, rssi: RSSI.intValue, known: known))
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first else { return }
        let name = KnownBoards.all.first { $0.value == restored.identifier }?.key ?? restored.name ?? "board"
        prepare(restored, name: name)
        record("restored \(name) after relaunch")
        // Wait for poweredOn before talking to it.
        phase = restored.state == .connected ? .connecting(name) : .waiting(name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.identifier != self.peripheral?.identifier {
            // Another known board turned on first: make it the current one.
            guard pendingOthers.contains(where: { $0.identifier == peripheral.identifier }),
                  let name = KnownBoards.all.first(where: { $0.value == peripheral.identifier })?.key else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            pendingOthers.removeAll { $0.identifier == peripheral.identifier }
            if let waiting = self.peripheral { central.cancelPeripheralConnection(waiting) }
            KnownBoards.lastConnected = name
            prepare(peripheral, name: name)
            record("\(name) turned on first")
        }
        cancelOthers()
        pinned = false
        central.stopScan()
        retryTask?.cancel()
        record("connected")
        if let name = boardName { phase = .connecting(name) }
        sessionTask = Task { await runSession() }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else {
            pendingOthers.removeAll { $0.identifier == peripheral.identifier }
            return
        }
        self.peripheral = nil
        record("connect failed, trying again")
        cancelOthers()
        scheduleRetry()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Ignore boards we already let go of.
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        saveCache()
        teardown()
        saveRange()
        mirror.finish()
        self.peripheral = nil
        record("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        // Straight back to waiting: the board went out of range or off.
        armAutoConnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BoardConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            discoveryWaiters.resumeFirst(.failure(error))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: Characteristic.serviceUUIDString) }) else {
            discoveryWaiters.resumeFirst(.failure(BoardError.bluetooth("Not a Onewheel.")))
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for cb in service.characteristics ?? [] {
            if let c = Characteristic(uuidString: cb.uuid.uuidString) { characteristics[c] = cb }
        }
        discoveryWaiters.resumeFirst(error.map { .failure($0) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor cb: CBCharacteristic, error: Error?) {
        guard let characteristic = Characteristic(uuidString: cb.uuid.uuidString) else { return }
        let data = cb.value ?? Data()

        if readWaiters[characteristic.rawValue].resumeFirst(error.map { .failure($0) } ?? .success(data)) {
            return
        }

        if characteristic == .uartRead {
            if let challenge = assembler.feed(data) { challengeWaiters.resumeFirst(.success(challenge)) }
            return
        }

        if phase == .unlocked {
            telemetry.apply(characteristic, data: data)
            // Board notifications keep arriving with the phone locked, unlike
            // timers, so they drive ride sampling too.
            recorder.update(board: boardName, telemetry: telemetry, live: true)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor cb: CBCharacteristic, error: Error?) {
        guard let characteristic = Characteristic(uuidString: cb.uuid.uuidString) else { return }
        writeWaiters[characteristic.rawValue].resumeFirst(error.map { .failure($0) } ?? .success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor cb: CBCharacteristic, error: Error?) {
        guard let characteristic = Characteristic(uuidString: cb.uuid.uuidString) else { return }
        notifyWaiters[characteristic.rawValue].resumeFirst(error.map { .failure($0) } ?? .success(()))
    }
}
