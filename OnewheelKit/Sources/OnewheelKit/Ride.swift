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

    public init(time: Date, latitude: Double? = nil, longitude: Double? = nil, altitude: Double? = nil,
                speedKPH: Double, batteryPercent: Int? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speedKPH = speedKPH
        self.batteryPercent = batteryPercent
    }

    public var hasLocation: Bool { latitude != nil && longitude != nil }
}

/// A recorded ride, and the numbers worth showing about it.
public struct Ride: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var board: String
    public var points: [RidePoint]
    /// Distance from the board's odometer, which beats GPS on tree-covered trails.
    public var odometerKm: Double?

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
            return pair.0.speedKPH >= 2 && gap < 10 ? total + gap : total
        }
    }

    public var gpsKm: Double {
        let located = points.filter(\.hasLocation)
        return zip(located, located.dropFirst()).reduce(0) { total, pair in
            total + Self.haversineKm(pair.0, pair.1)
        }
    }

    public var distanceKm: Double { odometerKm ?? gpsKm }

    public var averageMovingKPH: Double {
        movingTime > 0 ? distanceKm / (movingTime / 3600) : 0
    }

    public var batteryUsed: Int? {
        guard let start = points.first(where: { $0.batteryPercent != nil })?.batteryPercent,
              let end = points.last(where: { $0.batteryPercent != nil })?.batteryPercent else { return nil }
        return max(0, start - end)
    }

    public var hasRoute: Bool { points.filter(\.hasLocation).count >= 2 }

    /// Worth keeping: moved at least 100 m or rode for a minute.
    public var isWorthSaving: Bool { distanceKm >= 0.1 || movingTime >= 60 }

    /// Runs of consecutive located points that share a speed band, for
    /// drawing the route coloured by speed. Neighbouring runs share their
    /// joining point so the line has no gaps.
    public func speedSegments(bands: Int = 5, maxKPH: Double? = nil) -> [(band: Int, points: [RidePoint])] {
        let located = points.filter(\.hasLocation)
        guard located.count >= 2 else { return [] }
        let top = max(maxKPH ?? topSpeedKPH, 1)
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
