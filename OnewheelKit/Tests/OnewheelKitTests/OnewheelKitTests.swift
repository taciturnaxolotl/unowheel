import Foundation
import Testing
@testable import OnewheelKit

// Bytes measured on ow292642 (Pint, fw 5208, hw 5314).
let hydrusChallenge = Handshake.parseHex("09 8e 56 e3 66 f5 ac aa bc 75 87 69 52 67 7d 0c cb 01 2d 23")!
let hydrusResponse = Handshake.parseHex("09 8e 56 04 11 2b 0b db 29 44 e7 24 28 df 97 3c 25 ca 71 53")!

@Suite struct HandshakeTests {
    @Test func hydrusChallengeParses() throws {
        let challenge = try #require(Challenge(hydrusChallenge))
        #expect(!challenge.usesLegacyHeader)
        #expect(challenge.header == Data([0x09, 0x8e, 0x56]))
        #expect(challenge.nonce.count == 16)
    }

    @Test func capturedResponseIsPlausible() throws {
        let challenge = try #require(Challenge(hydrusChallenge))
        #expect(Handshake.isPlausibleResponse(hydrusResponse, for: challenge))
        var corrupted = hydrusResponse
        corrupted[5] ^= 0xff
        #expect(!Handshake.isPlausibleResponse(corrupted, for: challenge))
    }

    @Test func assemblerHandlesFragmentedHeaderlessFrames() {
        var assembler = ChallengeAssembler()
        let chunks = [1, 3, 1, 2, 2, 2, 2, 1, 2, 2, 2]
        var offset = 0
        var result: Challenge?
        for size in chunks {
            #expect(result == nil)
            result = assembler.feed(hydrusChallenge.subdata(in: offset..<(offset + size)))
            offset += size
        }
        #expect(result?.bytes == hydrusChallenge)
    }

    @Test func assemblerSkipsLeadingNoise() {
        var assembler = ChallengeAssembler()
        let legacy = Handshake.sealed(Data("CRX".utf8) + Data(repeating: 7, count: 16))
        #expect(assembler.feed(Data([0xaa, 0xbb]) + legacy.prefix(10)) == nil)
        #expect(assembler.feed(legacy.suffix(10))?.bytes == legacy)
    }

    @Test func geminiMatchesPonewheelReference() throws {
        // md5(nonce || key) computed independently with Python's hashlib.
        let challenge = try #require(Challenge(Handshake.sealed(Data("CRX".utf8) + Data(0..<16))))
        let response = Handshake.geminiResponse(for: challenge)
        #expect(response.hexString == "435258c15a4c9f0616f53b5bdde730fc15280847")
    }

    @Test func strategyAndKeepAlive() {
        #expect(Handshake.strategy(firmware: 3034) == .none)
        #expect(Handshake.strategy(firmware: 4034) == .gemini)
        #expect(Handshake.strategy(firmware: 5208) == .serverIssued)
        #expect(Handshake.keepAlive(firmware: 5208).characteristic == .rpm)
        #expect(Handshake.keepAlive(firmware: 4100).payload == Data([0x10, 0x04]))
    }
}

@Suite struct TelemetryTests {
    @Test func decodesUnlockedPint() {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: Data([0x14, 0xc2]))
        t.apply(.firmwareRevision, data: WireValue.encode(5050))
        t.apply(.batteryPercent, data: Data([0x00, 0x5d]))
        t.apply(.temperature, data: Data([0x1b, 0x18]))
        t.apply(.rideMode, data: Data([0x00, 0x05]))
        t.apply(.pitch, data: WireValue.encode(1800))
        t.apply(.batteryCells, data: WireValue.encode(0x3000 | 3400))
        t.apply(.currentAmps, data: WireValue.encode(UInt16(bitPattern: -500)))
        #expect(t.model == .pint)
        #expect(t.batteryPercent == 93)
        #expect(t.motorTemperatureC == 24)
        #expect(t.controllerTemperatureC == 27)
        #expect(t.model.rideModeName(t.rideMode!) == "Redwood")
        #expect(t.pitch == 0)
        #expect(abs((t.batteryCells[3] ?? 0) - 3.74) < 0.001)
        #expect(t.isRegenerating)
        #expect(t.looksUnlocked)
    }

    @Test func hydrusUsesPowerAndHidesCells() {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.firmwareRevision, data: WireValue.encode(5208))
        #expect(t.usesModernTelemetry)
        #expect(!t.reportsCellVoltages)
        t.apply(.batteryLow5, data: WireValue.encode(UInt16(bitPattern: -240)))
        t.apply(.currentAmps, data: WireValue.encode(500))
        #expect(t.powerWatts == -240)
        #expect(t.currentAmps == nil)
        #expect(t.isRegenerating)

        var old = Telemetry()
        old.apply(.hardwareRevision, data: WireValue.encode(5314))
        old.apply(.firmwareRevision, data: WireValue.encode(5050))
        #expect(old.reportsCellVoltages)
    }

    @Test func ignoresEmptyCellReads() {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.firmwareRevision, data: WireValue.encode(5208))
        t.apply(.batteryCells, data: Data([0, 0]))
        #expect(t.batteryCells.isEmpty)
        t.apply(.batteryCells, data: WireValue.encode(0xf000 | 3400))
        #expect(t.batteryCells.isEmpty)
        for cell in 0..<15 { t.apply(.batteryCells, data: WireValue.encode(UInt16(cell) << 12 | 3400)) }
        #expect(t.batteryCellsComplete)
    }

    @Test func speedFromRpm() {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.rpm, data: WireValue.encode(300))
        #expect(abs((t.speedKPH ?? 0) - 15.08) < 0.01)
    }

    @Test func characteristicRoundTrip() {
        #expect(Characteristic(uuidString: "e659f3ff-ea98-11e3-ac10-0800200c9a66") == .uartWrite)
        #expect(Characteristic.rpm.uuidString == "E659F30B-EA98-11E3-AC10-0800200C9A66")
        #expect(Characteristic(uuidString: "0000180a-0000-1000-8000-00805f9b34fb") == nil)
    }
}

@Suite struct StatusTests {
    @Test func footpadBits() {
        var t = Telemetry()
        t.apply(.statusError, data: WireValue.encode(0x0600))
        #expect(t.status?.frontPad == true)
        #expect(t.status?.backPad == true)
        #expect(t.status?.riderDetected == false)
        t.apply(.statusError, data: WireValue.encode(0x2000))
        #expect(t.status?.charging == true)
        #expect(t.status?.faults.isEmpty == true)
    }

    @Test func decodesDiagnosticLoopFromOw292642() {
        // One loop of 31c as captured from the 5208 Pint.
        let loop: [UInt16] = [0x0600, 0x0700, 0xa343, 0xb00b, 0xb103, 0xb203, 0xb303, 0xb40b, 0xb503,
                              0xb603, 0xb703, 0xb803, 0xb903, 0xefff, 0x108c, 0x1199, 0x12ff, 0x1378,
                              0x1400, 0x154f, 0x16fe, 0x17c0, 0x2008, 0x30c3, 0x310b, 0xc006, 0xf000,
                              0xf101, 0xf264, 0xf304, 0xd000, 0xd113, 0xd29c, 0xd3d4, 0x4000, 0x5000]
        var t = Telemetry()
        for word in loop { t.apply(.lastErrorCode, data: WireValue.encode(word)) }
        #expect(t.battery.cycles == 1)
        #expect(t.battery.healthPercent == 100)
        #expect(t.battery.cellType == "Sony VTC5D, 15s1p")
        #expect(t.battery.batteryID == 1_285_332)
        #expect(t.battery.bootloaderVersion == 8)
    }
}

@Suite struct RangeTests {
    func pint(battery: Int, rpm: Int = 0, watts: Int = 0) -> Telemetry {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.firmwareRevision, data: WireValue.encode(5208))
        t.apply(.batteryPercent, data: WireValue.encode(UInt16(battery)))
        t.apply(.rpm, data: WireValue.encode(UInt16(rpm)))
        t.apply(.batteryLow5, data: WireValue.encode(UInt16(bitPattern: Int16(watts))))
        return t
    }

    @Test func fallsBackToRatedRange() {
        let estimator = RangeEstimator()
        #expect(!estimator.isLearned)
        #expect(estimator.rangeKm(for: pint(battery: 50)) == 6.5)
    }

    @Test func learnsFromRiding() throws {
        var estimator = RangeEstimator()
        // ~300 rpm on a Pint is 15 km/h; 150 W there is 10 Wh/km.
        let riding = pint(battery: 80, rpm: 300, watts: 150)
        for _ in 0..<300 { estimator.record(riding, seconds: 1) }
        #expect(estimator.isLearned)
        let rate = try #require(estimator.whPerKm)
        #expect(abs(rate - 9.95) < 0.1)
        let range = try #require(estimator.rangeKm(for: pint(battery: 50)))
        #expect(abs(range - 69.5 / rate) < 0.01)
    }

    @Test func ignoresStandingStill() {
        var estimator = RangeEstimator()
        for _ in 0..<600 { estimator.record(pint(battery: 80, rpm: 0, watts: 40), seconds: 1) }
        #expect(estimator.whPerKm == nil)
    }

    @Test func survivesCoding() throws {
        var estimator = RangeEstimator()
        for _ in 0..<300 { estimator.record(pint(battery: 80, rpm: 300, watts: 150), seconds: 1) }
        let decoded = try JSONDecoder().decode(RangeEstimator.self, from: JSONEncoder().encode(estimator))
        #expect(decoded == estimator)
    }
}

@Suite struct PacketLoggerTests {
    /// Builds a little-endian pklg record carrying one ATT PDU over ACL.
    func record(sent: Bool, att: Data) -> Data {
        var l2cap = Data()
        l2cap.append(contentsOf: [UInt8(att.count & 0xff), UInt8(att.count >> 8), 0x04, 0x00])
        l2cap.append(att)
        var acl = Data([0x40, 0x20, UInt8(l2cap.count & 0xff), UInt8(l2cap.count >> 8)])
        acl.append(l2cap)
        var rec = Data()
        let length = UInt32(9 + acl.count)
        rec.append(contentsOf: withUnsafeBytes(of: length.littleEndian, Array.init))
        rec.append(Data(repeating: 0, count: 8))
        rec.append(sent ? 0x02 : 0x03)
        rec.append(acl)
        return rec
    }

    @Test func extractsResponseWrite() {
        var capture = record(sent: true, att: Data([0x0a, 0x59, 0x00]))
        capture += record(sent: true, att: Data([0x12, 0x16, 0x00]) + hydrusResponse)
        capture += record(sent: true, att: Data([0x12, 0x41, 0x00, 0x01, 0x01]))
        let findings = PacketLoggerCapture.findings(in: capture)
        #expect(findings.responses == [hydrusResponse])
    }

    @Test func realCaptureIfPresent() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Downloads/onewheel.pklg")
        guard let data = try? Data(contentsOf: url) else { return }
        #expect(PacketLoggerCapture.findings(in: data).responses == [hydrusResponse])
    }
}
