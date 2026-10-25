import Foundation

/// One sample of a recorded ride: where the phone was and what the board said.
public struct RidePoint: Codable, Equatable, Sendable {
    public var time: Date
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    /// Board speed in km/h, from wheel rpm.
    public var speedKPH: Double
    public var batteryPercent: Int?
    /// Motor power in watts; negative while braking (regen).
    public var watts: Double?
    public var motorTempC: Int?
    public var controllerTempC: Int?
    public var batteryTempC: Int?
    /// Pack voltage; it sags under load, more so in the cold and as cells age.
    public var volts: Double?
    /// Height from the phone's barometer, relative to where the ride began.
    /// Far steadier than GPS altitude, and kept when the GPS fix is dropped.
    public var climbM: Double?
    /// Board pitch in degrees as reported; nose up reads negative.
    public var pitch: Double?
    /// GPS fix accuracy in metres, for tuning the route cleanup. Present
    /// without a location when a fix arrived but was too poor to use.
    public var accuracyM: Double?
    /// Amp-hours drawn from the pack since the ride began, counted by the
    /// board itself rather than worked out from reported power.
    public var usedAh: Double?
    /// Amp-hours put back by braking and downhills, counted the same way.
    public var regenAh: Double?
    /// Ride mode value as written to `302`; see `BoardModel.rideModes`.
    public var rideMode: UInt16?
    /// Raw `30f` status word: footpad zones, charging and error code.
    public var status: UInt16?

    public init(time: Date, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil,
                speedKPH: Double, batteryPercent: Int? = nil, watts: Double? = nil,
                motorTempC: Int? = nil, controllerTempC: Int? = nil, batteryTempC: Int? = nil, volts: Double? = nil,
                climbM: Double? = nil, rideMode: UInt16? = nil, status: UInt16? = nil,
                pitch: Double? = nil, usedAh: Double? = nil, regenAh: Double? = nil, accuracyM: Double? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speedKPH = speedKPH
        self.batteryPercent = batteryPercent
        self.watts = watts
        self.motorTempC = motorTempC
        self.controllerTempC = controllerTempC
        self.batteryTempC = batteryTempC
        self.volts = volts
        self.climbM = climbM
        self.rideMode = rideMode
        self.status = status
        self.pitch = pitch
        self.usedAh = usedAh
        self.regenAh = regenAh
        self.accuracyM = accuracyM
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }

    /// Degrees the nose is tilted up. Pushback lifts it.
    public var noseUp: Double? { pitch.map { -$0 } }

    /// Off the pad or lifted by the nose, the wheel spins freely.
    public var isRidden: Bool {
        let level = pitch.map { abs($0) < Self.levelDegrees } ?? true
        let onPad = status.map(BoardStatus.init(raw:)).map { $0.riderDetected && ($0.frontPad || $0.backPad) } ?? true
        return level && onPad
    }

    static let levelDegrees = 15.0

    mutating func dropLocation() {
        latitude = nil
        longitude = nil
        altitude = nil
    }
}

/// A recorded ride, and the numbers worth showing about it.
public struct Ride: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var board: String
    public var points: [RidePoint]
    /// Distance from the board's odometer, which beats GPS on tree-covered trails.
    public var odometerKm: Double?
    /// Place names for the start and end, filled in after the ride by
    /// reverse geocoding. A park or neighbourhood when there is one.
    public var startPlace: String?
    public var endPlace: String?
    /// Your own name for the ride, if you've given it one.
    public var customTitle: String?
    /// Weather where and when the ride started, looked up after the ride.
    public var weather: Weather?
    /// Set by `cleanedRoute`; worked out on load, never saved.
    public internal(set) var routeQuality = RouteQuality.good

    private enum CodingKeys: String, CodingKey {
        case id, board, points, odometerKm, startPlace, endPlace, customTitle, weather
    }

    public init(id: UUID = UUID(), board: String, points: [RidePoint] = [], odometerKm: Double? = nil) {
        self.id = id
        self.board = board
        self.points = points
        self.odometerKm = odometerKm
    }

    public var startedAt: Date { points.first?.time ?? .distantPast }
    public var endedAt: Date { points.last?.time ?? .distantPast }
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Below this the board is standing still, or being carried.
    public static let movingKPH = 2.0

    public var topSpeedKPH: Double { points.map(\.speedKPH).max() ?? 0 }

    /// Time spent above walking pace.
    public var movingTime: TimeInterval {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.time.timeIntervalSince(pair.0.time)
            return pair.0.speedKPH >= Self.movingKPH && gap < 10 ? total + gap : total
        }
    }

    public var gpsKm: Double { points.gpsKm }
    public var wheelKm: Double { points.wheelKm }

    /// The odometer when it was read, then wheel speed. GPS only for rides
    /// with no speed at all.
    public var distanceKm: Double { odometerKm ?? (wheelKm > 0 ? wheelKm : gpsKm) }

    public var averageMovingKPH: Double {
        movingTime > 0 ? distanceKm / (movingTime / 3600) : 0
    }

    public var batteryUsed: Int? {
        guard let start = points.first(where: { $0.batteryPercent != nil })?.batteryPercent,
              let end = points.last(where: { $0.batteryPercent != nil })?.batteryPercent else { return nil }
        return max(0, start - end)
    }

    public var hasRoute: Bool { points.filter(\.hasLocation).count >= 2 }

    /// Energy drawn from the pack, in watt-hours, from power over time.
    public var energyWh: Double { integrateWatts { max($0, 0) } }

    /// Energy put back by braking and downhills.
    public var regenWh: Double { integrateWatts { max(-$0, 0) } }

    /// Highest sustained motor power. Power and speed are sampled on their
    /// own clocks, so one sample can pair a spike with the wrong speed;
    /// averaging three caps those without hiding a real burst.
    public var peakWatts: Double? {
        let watts = points.compactMap(\.watts)
        guard watts.count >= 3 else { return watts.max() }
        var peak = -Double.infinity
        for i in 2..<watts.count {
            peak = max(peak, (watts[i - 2] + watts[i - 1] + watts[i]) / 3)
        }
        return peak
    }

    public var hasPower: Bool { points.contains { $0.watts != nil } }

    public var peakNoseUp: Double? { points.compactMap(\.noseUp).max() }

    /// Lowest speed the nose stayed lifted at; a bump lifts it for one sample only.
    public var pushbackKPH: Double? {
        func lifted(_ i: Int, by degrees: Double) -> Bool {
            points.indices.contains(i) && (points[i].noseUp ?? 0) >= degrees
        }
        return points.indices.filter { i in
            points[i].speedKPH >= Self.pushbackMinimumKPH && lifted(i, by: Self.pushbackNoseUp)
                && (lifted(i - 1, by: Self.pushbackNoseUp / 2) || lifted(i + 1, by: Self.pushbackNoseUp / 2))
        }.map { points[$0].speedKPH }.min()
    }

    static let pushbackNoseUp = 2.0
    /// Slower than this, a lifted nose is the rider, not the board.
    static let pushbackMinimumKPH = 15.0

    /// Charge the board counted going out and coming back over the ride.
    public var ampHours: (used: Double, regen: Double)? {
        guard let used = points.compactMap(\.usedAh).last else { return nil }
        return (used, points.compactMap(\.regenAh).last ?? 0)
    }

    /// Mean pack volts from the counters: the board's power figure is
    /// sampled on its own clock and spikes, the counters aren't.
    public var countedVolts: Double? {
        guard let (used, regen) = ampHours, let wh = powerWh else { return nil }
        let ampHours = used + regen
        return ampHours > 0 ? wh / ampHours : nil
    }

    /// Energy either way, before regen is netted off.
    private var powerWh: Double? {
        guard hasPower else { return nil }
        return energyWh + regenWh
    }

    /// Wh per km over the ride, net of regen.
    public var whPerKm: Double? {
        guard hasPower, distanceKm > 0.1 else { return nil }
        return max(energyWh - regenWh, 0) / distanceKm
    }

    /// Wh per km the pack actually gave up, crediting regen the way the
    /// range estimate does.
    public var packWhPerKm: Double? {
        guard hasPower, distanceKm > 0.1 else { return nil }
        return max(energyWh - regenWh * RangeEstimator.regenCredit, 0) / distanceKm
    }

    /// The temperature the board started in: the pack's own reading, then
    /// the motor's (it matches the air once the board has sat a while),
    /// then the weather.
    public var startTemperatureC: Double? {
        points.lazy.compactMap(\.batteryTempC).first.map(Double.init)
            ?? points.lazy.compactMap(\.motorTempC).first.map(Double.init)
            ?? weather?.temperatureC
    }

    /// Metres climbed, from the barometer when the ride has it, else GPS
    /// altitude. Wobble under 2 m is ignored.
    public var elevationGainM: Double? {
        let barometric = points.compactMap(\.climbM)
        let altitudes = barometric.count > 1 ? barometric : points.compactMap(\.altitude)
        guard altitudes.count > 1 else { return nil }
        var gain = 0.0
        var anchor = altitudes[0]
        for altitude in altitudes.dropFirst() {
            if altitude - anchor >= 2 {
                gain += altitude - anchor
                anchor = altitude
            } else if altitude < anchor {
                anchor = altitude
            }
        }
        return gain
    }

    public var maxMotorTempC: Int? { points.compactMap(\.motorTempC).max() }
    public var maxControllerTempC: Int? { points.compactMap(\.controllerTempC).max() }

    private func integrateWatts(_ transform: (Double) -> Double) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            guard let watts = pair.0.watts else { return total }
            let gap = pair.1.time.timeIntervalSince(pair.0.time)
            return gap < 10 ? total + transform(watts) * gap / 3600 : total
        }
    }

    /// Ends within 300 m of where it began.
    public var isLoop: Bool {
        guard let first = points.first(where: \.hasLocation), let last = points.last(where: \.hasLocation) else { return false }
        return Self.haversineKm(first, last) < 0.3
    }

    /// "Evening loop at Alum Creek Park", "Westerville to Columbus",
    /// or just "Morning ride" when there's no place yet.
    public func title(calendar: Calendar = .current) -> String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let hour = calendar.component(.hour, from: startedAt)
        let time = switch hour {
        case 5..<12: "Morning"
        case 12..<17: "Afternoon"
        case 17..<21: "Evening"
        default: "Night"
        }
        guard let start = startPlace else { return "\(time) ride" }
        if let end = endPlace, end != start, !isLoop { return "\(start) to \(end)" }
        return isLoop ? "\(time) loop at \(start)" : "\(time) ride in \(start)"
    }

    /// Worth keeping: moved at least 100 m or rode for a minute.
    public var isWorthSaving: Bool { distanceKm >= 0.1 || movingTime >= 60 }

    /// Runs of consecutive located points that share a speed band, for
    /// drawing the route coloured by speed. Neighbouring runs share their
    /// joining point so the line has no gaps.
    public func speedSegments(bands: Int = 5) -> [(band: Int, points: [RidePoint])] {
        let located = points.filter(\.hasLocation)
        guard located.count >= 2 else { return [] }
        let top = max(topSpeedKPH, 1)
        func band(_ p: RidePoint) -> Int { min(bands - 1, Int(p.speedKPH / top * Double(bands))) }
        var segments: [(band: Int, points: [RidePoint])] = []
        for point in located {
            let b = band(point)
            if let last = segments.last, last.band == b {
                segments[segments.count - 1].points.append(point)
            } else {
                let joint = segments.last?.points.last
                segments.append((b, (joint.map { [$0] } ?? []) + [point]))
            }
        }
        return segments.filter { $0.points.count >= 2 }
    }

    /// GPS jitters a few metres; a short moving average makes the line
    /// read as the path you actually rode. Speed is left as recorded.
    public func smoothed(window: Int = 5) -> Ride {
        let located = points.enumerated().filter { $0.element.hasLocation }
        guard located.count > window else { return self }
        var copy = self
        let half = window / 2
        for (i, entry) in located.enumerated() {
            let lo = max(0, i - half), hi = min(located.count - 1, i + half)
            let slice = located[lo...hi].map(\.element)
            copy.points[entry.offset].latitude = slice.compactMap(\.latitude).reduce(0, +) / Double(slice.count)
            copy.points[entry.offset].longitude = slice.compactMap(\.longitude).reduce(0, +) / Double(slice.count)
        }
        return copy
    }

    static func haversineKm(_ a: RidePoint, _ b: RidePoint) -> Double {
        guard let lat1 = a.latitude, let lon1 = a.longitude, let lat2 = b.latitude, let lon2 = b.longitude else { return 0 }
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

extension Collection where Element == RidePoint {
    public var gpsKm: Double {
        let located = filter(\.hasLocation)
        return zip(located, located.dropFirst()).reduce(0) { $0 + Ride.haversineKm($1.0, $1.1) }
    }

    /// Distance from wheel speed over time; matches the odometer within a couple of percent.
    public var wheelKm: Double {
        zip(self, dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.time.timeIntervalSince(pair.0.time)
            return gap < 10 ? total + pair.0.speedKPH * gap / 3600 : total
        }
    }
}
