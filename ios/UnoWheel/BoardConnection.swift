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
        case .missingCharacteristic(let c): "The board has no \(c.rawValue) characteristic."
        case .timeout(let what): "Timed out waiting for \(what)."
        case .bluetooth(let message): message
        case .rejected: "The board didn't accept that unlock response."
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
    private(set) var boardName: String?
    private(set) var nickname: String?

    /// What to call the board in the UI: your nickname, else its serial.
    var displayName: String? { nickname ?? boardName }
    private(set) var telemetry = Telemetry()
    private(set) var challenge: Challenge?
    private(set) var log: [String] = []
    private(set) var range = RangeEstimator()
    private(set) var unlockedAt: Date?

    var rangeKm: Double? { range.rangeKm(for: telemetry) }

    private(set) var autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true

    func setAutoConnect(_ enabled: Bool) {
        autoConnect = enabled
        UserDefaults.standard.set(enabled, forKey: "autoConnect")
        if enabled {
            autoConnectPaused = false
            armAutoConnect()
        } else {
            cancelWaiting()
        }
    }

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
    @ObservationIgnored private var userDisconnected = false
    @ObservationIgnored private let mirror = RideMirror()
    @ObservationIgnored private var mirrorTask: Task<Void, Never>?
    @ObservationIgnored private var lastTick = Date.now
    @ObservationIgnored private var lastRangeSave = Date.now
    /// Set when you disconnect by hand, so we don't immediately grab the board
    /// back. Cleared by picking a board or relaunching.
    @ObservationIgnored private var autoConnectPaused = false
    @ObservationIgnored private var isDemo = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "sh.dunkirk.unowheel.central",
        ])
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
        guard isConnected else { return }
        if phase == .unlocked {
            range.record(telemetry, seconds: elapsed)
            if now.timeIntervalSince(lastRangeSave) > 30 { saveRange() }
        }
        mirror.sync(name: displayName, telemetry: telemetry, unlocked: phase == .unlocked,
                    rangeKm: rangeKm, rangeLearned: range.isLearned, startedAt: unlockedAt)
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
        telemetry = t
        unlockedAt = .now.addingTimeInterval(-600)
        phase = .unlocked
    }
    #endif

    // MARK: - Auto-connect

    /// Asks iOS to connect to the last board whenever it shows up. The request
    /// never times out, and survives the app being suspended or relaunched.
    func armAutoConnect() {
        guard autoConnect, !autoConnectPaused, central.state == .poweredOn, peripheral == nil,
              let name = KnownBoards.lastConnected, let id = KnownBoards.all[name],
              let target = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        prepare(target, name: name)
        phase = .waiting(name)
        record("waiting for \(name)")
        central.connect(target)
    }

    func cancelWaiting() {
        guard case .waiting = phase else { return }
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        autoConnectPaused = true
        phase = .idle
        startScan()
    }

    private func prepare(_ target: CBPeripheral, name: String) {
        boardName = name
        nickname = KnownBoards.nickname(for: name)
        telemetry = Telemetry()
        challenge = nil
        characteristics = [:]
        assembler.reset()
        unlockedAt = nil
        loadRange(for: name)
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
        if case .waiting = phase { return }
        phase = .scanning
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
            phase = .failed("Lost track of \(board.name). Scan again.")
            return
        }
        central.stopScan()
        if let pending = peripheral, pending.identifier != target.identifier {
            central.cancelPeripheralConnection(pending)
        }
        userDisconnected = false
        autoConnectPaused = false
        prepare(target, name: board.name)
        phase = .connecting(board.name)
        record("connecting to \(board.name)")
        central.connect(target)
    }

    func disconnect() {
        userDisconnected = true
        autoConnectPaused = true
        saveRange()
        teardown()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        mirror.finish()
        phase = .idle
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
            fail(error)
        }
    }

    /// Writes an unlock response and checks that the board starts serving data.
    func submit(_ response: Data, remember: Bool = true) async throws {
        record("response \(response.spacedHex)")
        phase = .handshaking
        do {
            try await write(.uartWrite, response, withResponse: true)
            try await Task.sleep(for: .milliseconds(600))
            telemetry.apply(.rideMode, data: try await read(.rideMode))
            telemetry.apply(.batteryPercent, data: try await read(.batteryPercent))
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
            throw BoardError.bluetooth("A response is 20 bytes, 40 hex characters.")
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
        for characteristic in Characteristic.telemetry where characteristics[characteristic] != nil {
            if let data = try? await read(characteristic) { telemetry.apply(characteristic, data: data) }
            try? await setNotify(characteristic, true)
        }
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
        Task {
            do {
                try await write(.rideMode, WireValue.encode(mode.value), withResponse: true)
                telemetry.apply(.rideMode, data: try await read(.rideMode))
            } catch { record("ride mode: \(error.localizedDescription)") }
        }
    }

    func setLights(_ on: Bool) {
        Task {
            do {
                try await write(.lightingMode, WireValue.encode(on ? 1 : 0), withResponse: true)
                telemetry.apply(.lightingMode, data: try await read(.lightingMode))
            } catch { record("lights: \(error.localizedDescription)") }
        }
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
            if phase == .bluetoothOff || phase == .idle {
                armAutoConnect()
                startScan()
            }
        case .poweredOff, .unauthorized, .unsupported:
            teardown()
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
        if restored.state == .connected {
            phase = .connecting(name)
            sessionTask = Task { await runSession() }
        } else {
            phase = .waiting(name)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        record("connected")
        if let name = boardName { phase = .connecting(name) }
        sessionTask = Task { await runSession() }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        if autoConnect, !autoConnectPaused, !userDisconnected {
            record("connect failed, waiting again")
            armAutoConnect()
            return
        }
        fail(BoardError.bluetooth(error?.localizedDescription ?? "Couldn't connect."))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        teardown()
        saveRange()
        guard !userDisconnected else { return }
        record("disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        mirror.finish()
        self.peripheral = nil
        if autoConnect, !autoConnectPaused {
            armAutoConnect()
        } else {
            phase = .failed("The board disconnected.")
        }
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
            discoveryWaiters.resumeFirst(.failure(BoardError.bluetooth("This doesn't look like a Onewheel.")))
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

        if phase == .unlocked { telemetry.apply(characteristic, data: data) }
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
