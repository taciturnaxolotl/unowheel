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
    /// Ride mode value as written to `302`; see `BoardModel.rideModes`.
    public var rideMode: UInt16?
    /// Raw `30f` status word: footpad zones, charging and error code.
    public var status: UInt16?

    public init(time: Date, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil,
                speedKPH: Double, batteryPercent: Int? = nil, watts: Double? = nil,
                motorTempC: Int? = nil, controllerTempC: Int? = nil, batteryTempC: Int? = nil, volts: Double? = nil,
                climbM: Double? = nil, rideMode: UInt16? = nil, status: UInt16? = nil) {
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
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }

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

    public init(id: UUID = UUID(), board: String, points: [RidePoint] = [], odometerKm: Double? = nil) {
        self.id = id
        self.board = board
        self.points = points
        self.odometerKm = odometerKm
    }

    public var startedAt: Date { points.first?.time ?? .distantPast }
    public var endedAt: Date { points.last?.time ?? .distantPast }
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    public var topSpeedKPH: Double { points.map(\.speedKPH).max() ?? 0 }

    /// Time spent above walking pace.
    public var movingTime: TimeInterval {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.time.timeIntervalSince(pair.0.time)
            return pair.0.speedKPH >= Self.movingKPH && gap < 10 ? total + gap : total
        }
    }

    public var gpsKm: Double {
        let located = points.filter(\.hasLocation)
        return zip(located, located.dropFirst()).reduce(0) { total, pair in
            total + Self.haversineKm(pair.0, pair.1)
        }
    }

    /// Distance from wheel speed over time. Matches the odometer within a
    /// couple of percent, where GPS can be far off near buildings.
    public var wheelKm: Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.time.timeIntervalSince(pair.0.time)
            return gap < 10 ? total + pair.0.speedKPH * gap / 3600 : total
        }
    }

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

    public var peakWatts: Double? { points.compactMap(\.watts).max() }

    public var hasPower: Bool { points.contains { $0.watts != nil } }

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

    /// Drops GPS fixes that can't be part of the ride, keeping board data
    /// for every point. Tuned on real rides that went in and out of buildings.
    public func cleanedRoute() -> Ride {
        droppingCarriedFixes().droppingFrozenFixes().droppingStrandedFixes()
    }

    /// Below this the board is standing still, or being carried.
    public static let movingKPH = 2.0
    private static let carriedAfter: TimeInterval = 3
    private static let frozenRun = 4
    private static let trustedJumpGap: TimeInterval = 10
    private static let jumpSlack = 1.5
    private static let jumpToleranceKm = 0.05
    private static let strandedRun = 10

    /// Fixes once the board has been still for a few seconds: it's being
    /// carried inside. The first stopped fixes are kept; that's where you stopped.
    private func droppingCarriedFixes() -> Ride {
        var copy = self
        var stillSince: Date?
        for i in copy.points.indices {
            guard copy.points[i].speedKPH < Self.movingKPH else {
                stillSince = nil
                continue
            }
            let since = stillSince ?? copy.points[i].time
            stillSince = since
            if copy.points[i].time.timeIntervalSince(since) > Self.carriedAfter { copy.points[i].dropLocation() }
        }
        return copy
    }

    /// iOS keeps reporting the last fix when it loses the sky. A coordinate
    /// held for several samples is stale throughout; a brief repeat keeps its first.
    private func droppingFrozenFixes() -> Ride {
        var copy = self
        let runs = locatedRuns { a, b in points[a].latitude != points[b].latitude || points[a].longitude != points[b].longitude }
        for run in runs {
            (run.count >= Self.frozenRun ? run[...] : run.dropFirst()).forEach { copy.points[$0].dropLocation() }
        }
        return copy
    }

    /// A short run cut off from the rest by a jump the board couldn't have
    /// made, like the first fixes after stepping outside. After a long gap
    /// in fixes a jump is expected, so it's trusted.
    private func droppingStrandedFixes() -> Ride {
        let runs = locatedRuns { a, b in
            let seconds = points[b].time.timeIntervalSince(points[a].time)
            let fastest = points[a...b].map(\.speedKPH).max() ?? 0
            let reachableKm = fastest * max(seconds, 1) / 3600 * Self.jumpSlack + Self.jumpToleranceKm
            return seconds < Self.trustedJumpGap && Self.haversineKm(points[a], points[b]) > reachableKm
        }
        let longest = runs.map(\.count).max() ?? 0
        var copy = self
        for run in runs where run.count < longest && run.count < Self.strandedRun {
            run.forEach { copy.points[$0].dropLocation() }
        }
        return copy
    }

    /// Indices of located points in runs; a new run starts wherever
    /// `breaks(previous, next)` is true.
    private func locatedRuns(breakingWhere breaks: (Int, Int) -> Bool) -> [[Int]] {
        var runs: [[Int]] = []
        for i in points.indices where points[i].hasLocation {
            if let last = runs.last?.last, !breaks(last, i) {
                runs[runs.count - 1].append(i)
            } else {
                runs.append([i])
            }
        }
        return runs
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
