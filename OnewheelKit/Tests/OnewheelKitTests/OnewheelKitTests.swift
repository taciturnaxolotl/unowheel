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

    @Test func topSpeedPerMode() {
        #expect(BoardModel.pint.topSpeedMPH(mode: 5) == 12)
        #expect(BoardModel.pint.topSpeedMPH(mode: 7) == 16)
        #expect(BoardModel.pintX.topSpeedMPH(mode: 8) == 18)
        #expect(BoardModel.gts.topSpeedMPH(mode: 4) == 18)
        #expect(BoardModel.gts.topSpeedMPH(mode: 8) == 25)
        #expect(BoardModel.pint.topSpeedMPH(mode: nil) == 16)
    }

    @Test func telemetrySurvivesCoding() throws {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.batteryPercent, data: WireValue.encode(72))
        t.apply(.lastErrorCode, data: WireValue.encode(0xf264))
        let decoded = try JSONDecoder().decode(Telemetry.self, from: JSONEncoder().encode(t))
        #expect(decoded == t)
        #expect(decoded.battery.healthPercent == 100)
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
        #expect(t.status?.error == nil)
        // Seen while charging on its side: charging flag plus error 4.
        t.apply(.statusError, data: WireValue.encode(0x2004))
        #expect(t.status?.charging == true)
        #expect(t.status?.error?.title == "Start in the ready position")
        #expect(BoardErrorCode(code: 99).title == "Error 99")
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

@Suite struct ChargeTests {
    @Test func chargingIsNotRegen() {
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.firmwareRevision, data: WireValue.encode(5208))
        // Measured on ow292642 while charging.
        t.apply(.statusError, data: WireValue.encode(0x2004))
        t.apply(.batteryLow5, data: WireValue.encode(UInt16(bitPattern: -170)))
        #expect(t.isCharging)
        #expect(!t.isRegenerating)
        #expect(t.chargingWatts == 170)
    }

    @Test func estimatesFromPowerFirst() throws {
        var session = ChargeSession(startedAt: .distantPast)
        session.record(percent: 57, watts: 185, at: .distantPast)
        let seconds = try #require(session.secondsToFull(packWattHours: 139))
        // 31 points to the jump at 88%, at 139 Wh / 100 / 185 W each.
        #expect(abs(seconds - 31 * 1.39 / 185 * 3600) < 1)
        #expect(!session.isMeasured)
    }

    @Test func switchesToMeasuredRate() throws {
        // Real 5208 Pint charge: 57% -> 88% at ~28 s per point.
        let start = Date(timeIntervalSince1970: 0)
        var session = ChargeSession(startedAt: start)
        session.record(percent: 57, watts: 185, at: start)
        for (i, pct) in (58...70).enumerated() {
            session.record(percent: pct, watts: 187, at: start.addingTimeInterval(12 + Double(i) * 28))
        }
        #expect(session.isMeasured)
        let seconds = try #require(session.secondsToFull(packWattHours: 139))
        #expect(abs(seconds - 18 * 28) < 1)
    }

    @Test func toppingOff() {
        #expect(ChargeSession.isToppingOff(percent: 100, watts: 86))
        // Low, noisy power at the end must not flip it back.
        #expect(ChargeSession.isToppingOff(percent: 100, watts: 0))
        #expect(!ChargeSession.isToppingOff(percent: 80, watts: 190))
        var session = ChargeSession()
        session.record(percent: 100, watts: 20)
        #expect(session.secondsToFull(packWattHours: 139) == nil)
    }

    @Test func voltageFromChargeCounters() throws {
        // 36 s of the real charge at 57%: 184 W and +168 units on 314.
        var t = Telemetry()
        t.apply(.hardwareRevision, data: WireValue.encode(5314))
        t.apply(.firmwareRevision, data: WireValue.encode(5208))
        t.apply(.statusError, data: WireValue.encode(0x2004))
        t.apply(.batteryLow5, data: WireValue.encode(UInt16(bitPattern: -184)))
        t.apply(.tripAmpHours, data: WireValue.encode(0))
        var estimator = PackVoltageEstimator()
        let start = Date(timeIntervalSince1970: 0)
        for second in 0...36 {
            t.apply(.tripRegenAmpHours, data: WireValue.encode(UInt16(5842 + second * 168 / 36)))
            estimator.record(t, at: start.addingTimeInterval(Double(second)))
        }
        let volts = try #require(estimator.volts)
        #expect(abs(volts - 60.8) < 0.5)
    }

    @Test func throttlesSamples() {
        let start = Date(timeIntervalSince1970: 0)
        var session = ChargeSession(startedAt: start)
        for i in 0..<10 { session.record(percent: 50, watts: 170, at: start.addingTimeInterval(Double(i))) }
        #expect(session.samples.count == 1)
    }
}

@Suite struct RideTests {
    func point(_ second: Double, lat: Double, speed: Double, battery: Int = 80) -> RidePoint {
        RidePoint(time: Date(timeIntervalSince1970: second), latitude: lat, longitude: -83.0,
                  speedKPH: speed, batteryPercent: battery)
    }

    @Test func gpsDistanceAndTime() {
        // 0.001 degrees of latitude is about 111 m.
        let ride = Ride(board: "ow1", points: (0...10).map { point(Double($0), lat: 40 + Double($0) * 0.001, speed: 20) })
        #expect(abs(ride.gpsKm - 1.112) < 0.01)
        #expect(ride.duration == 10)
        #expect(ride.movingTime == 10)
        #expect(ride.isWorthSaving)
    }

    @Test func prefersOdometer() {
        var ride = Ride(board: "ow1", points: [point(0, lat: 40, speed: 10), point(60, lat: 40.01, speed: 10)])
        ride.odometerKm = 0.9
        #expect(ride.distanceKm == 0.9)
    }

    @Test func batteryAndTop() {
        let ride = Ride(board: "ow1", points: [point(0, lat: 40, speed: 5, battery: 90),
                                               point(1, lat: 40.001, speed: 24, battery: 88),
                                               point(2, lat: 40.002, speed: 3, battery: 85)])
        #expect(ride.topSpeedKPH == 24)
        #expect(ride.batteryUsed == 5)
    }

    @Test func segmentsJoinWithoutGaps() {
        let speeds: [Double] = [2, 3, 20, 21, 22, 4]
        let ride = Ride(board: "ow1", points: speeds.enumerated().map { point(Double($0.offset), lat: 40 + Double($0.offset) * 0.001, speed: $0.element) })
        let segments = ride.speedSegments(bands: 2)
        #expect(segments.map(\.band) == [0, 1, 0])
        #expect(segments[1].points.first == segments[0].points.last)
        #expect(segments[2].points.first == segments[1].points.last)
    }

    @Test func smoothing() {
        // A straight line with every other point nudged sideways.
        let zigzag = Ride(board: "ow1", points: (0..<20).map { i in
            RidePoint(time: Date(timeIntervalSince1970: Double(i)), latitude: 40 + Double(i) * 0.001,
                      longitude: -83 + (i.isMultiple(of: 2) ? 0.0002 : -0.0002), speedKPH: 15)
        })
        let smooth = zigzag.smoothed()
        let wiggle = { (r: Ride) in r.points.compactMap(\.longitude).map { abs($0 + 83) }.max() ?? 0 }
        #expect(wiggle(smooth) < wiggle(zigzag) / 2)
        #expect(smooth.points.map(\.speedKPH) == zigzag.points.map(\.speedKPH))
    }

    @Test func titles() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 18:00 UTC start; a loop that comes back to the start.
        let start = Date(timeIntervalSince1970: 18 * 3600)
        var loop = Ride(board: "ow1", points: [
            RidePoint(time: start, latitude: 40, longitude: -83, speedKPH: 10),
            RidePoint(time: start + 600, latitude: 40.01, longitude: -83, speedKPH: 10),
            RidePoint(time: start + 1200, latitude: 40.0005, longitude: -83, speedKPH: 10),
        ])
        #expect(loop.title(calendar: utc) == "Evening ride")
        loop.startPlace = "Alum Creek Park"
        #expect(loop.title(calendar: utc) == "Evening loop at Alum Creek Park")

        var trip = Ride(board: "ow1", points: [
            RidePoint(time: start - 10 * 3600, latitude: 40, longitude: -83, speedKPH: 10),
            RidePoint(time: start - 9 * 3600, latitude: 40.05, longitude: -83, speedKPH: 10),
        ])
        trip.startPlace = "Westerville"
        trip.endPlace = "Columbus"
        #expect(trip.title(calendar: utc) == "Westerville to Columbus")
        trip.endPlace = "Westerville"
        #expect(trip.title(calendar: utc) == "Morning ride in Westerville")
        trip.customTitle = "Commute"
        #expect(trip.title(calendar: utc) == "Commute")
    }

    @Test func energyAndClimb() {
        // An hour at 200 W out, then an hour at 50 W regen, 10 km in all.
        var points: [RidePoint] = []
        for i in 0..<3600 { points.append(RidePoint(time: Date(timeIntervalSince1970: Double(i)), altitude: 100 + Double(i) / 360, speedKPH: 10, watts: 200, motorTempC: 30 + i / 360)) }
        for i in 3600..<7200 { points.append(RidePoint(time: Date(timeIntervalSince1970: Double(i)), altitude: 110, speedKPH: 10, watts: -50)) }
        let ride = Ride(board: "ow1", points: points, odometerKm: 10)
        #expect(abs(ride.energyWh - 200) < 0.2)
        #expect(abs(ride.regenWh - 50) < 0.2)
        #expect(abs((ride.whPerKm ?? 0) - 15) < 0.1)
        #expect(ride.peakWatts == 200)
        #expect(abs((ride.elevationGainM ?? 0) - 10) < 2)
        #expect(ride.maxMotorTempC == 39)
    }

    private func fix(_ t: Double, _ lat: Double, _ speed: Double) -> RidePoint {
        RidePoint(time: Date(timeIntervalSince1970: t), latitude: lat, longitude: -83, speedKPH: speed)
    }

    @Test func dropsFixesWhileCarried() {
        var points = (0..<6).map { fix(Double($0), 40 + Double($0) * 0.00003, 10) }
        points += (6..<12).map { fix(Double($0), 40.0002 + Double($0) * 0.000001, 0) }
        let clean = Ride(board: "ow1", points: points).cleanedRoute()
        #expect(clean.points[0..<10].allSatisfy { $0.hasLocation })
        #expect(clean.points[10..<12].allSatisfy { !$0.hasLocation })
    }

    @Test func dropsFrozenFixes() {
        var points = (0..<10).map { fix(Double($0), 40 + Double($0) * 0.00003, 10) }
        points += (10..<15).map { fix(Double($0), 40.0003, 10) }   // frozen: all stale
        points += (15..<17).map { fix(Double($0), 40.0005, 10) }   // brief repeat: keep the first
        points += (17..<25).map { fix(Double($0), 40 + Double($0) * 0.00003, 10) }
        let clean = Ride(board: "ow1", points: points).cleanedRoute()
        #expect(clean.points[10..<15].allSatisfy { !$0.hasLocation })
        #expect(clean.points[15].hasLocation)
        #expect(!clean.points[16].hasLocation)
        #expect(clean.points[17].hasLocation)
    }

    @Test func dropsStrandedFixesButTrustsLongGaps() {
        var points = (0..<3).map { fix(Double($0), 40.01 + Double($0) * 0.00003, 10) }  // ~1 km off
        points += (3..<18).map { fix(Double($0), 40 + Double($0) * 0.00003, 10) }
        points += (40..<45).map { fix(Double($0), 40.02 + Double($0) * 0.00003, 10) } // after a long gap
        let clean = Ride(board: "ow1", points: points).cleanedRoute()
        #expect(clean.points[0..<3].allSatisfy { !$0.hasLocation })
        #expect(clean.points[3...].allSatisfy { $0.hasLocation })
    }

    @Test func cleansIndoorFixes() {
        func p(_ t: Double, _ lat: Double, _ speed: Double) -> RidePoint {
            RidePoint(time: Date(timeIntervalSince1970: t), latitude: lat, longitude: -83, speedKPH: speed)
        }
        var points = [p(0, 40.0100, 10), p(1, 40.0100, 10), p(2, 40.0101, 10)]   // bad first fixes, ~1 km off
        points += (3..<20).map { p(Double($0), 40 + Double($0) * 0.00003, 10) } // the real ride
        points += (20..<30).map { p(Double($0), 40.0006, 5) }                   // GPS freezes going round a building
        points.append(p(30, 40.0010, 0.1))                                      // catches up as you stop
        points.append(p(40, 40.0040, 0))                                        // carried inside
        let clean = Ride(board: "ow1", points: points).cleanedRoute()
        #expect(!clean.points[0].hasLocation)
        #expect(clean.points[5].hasLocation)
        #expect(clean.points[20..<30].allSatisfy { !$0.hasLocation })
        #expect(clean.points[30].hasLocation)
        #expect(!clean.points[31].hasLocation)
    }

    @Test func tooShortToKeep() {
        let ride = Ride(board: "ow1", points: [point(0, lat: 40, speed: 0), point(20, lat: 40, speed: 1)])
        #expect(!ride.isWorthSaving)
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
