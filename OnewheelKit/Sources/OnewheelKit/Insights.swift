import Foundation

/// Weather at the start of a ride.
public struct Weather: Codable, Equatable, Sendable {
    public var temperatureC: Double
    public var windKPH: Double
    public var precipitationMM: Double
    public var humidityPercent: Double?

    public init(temperatureC: Double, windKPH: Double, precipitationMM: Double, humidityPercent: Double? = nil) {
        self.temperatureC = temperatureC
        self.windKPH = windKPH
        self.precipitationMM = precipitationMM
        self.humidityPercent = humidityPercent
    }
}

extension Telemetry {
    /// The board's temperature right now, matching `Ride.startTemperatureC`.
    public var boardTemperatureC: Double? {
        (batteryTemperatureC ?? motorTemperatureC).map(Double.init)
    }
}

/// Wh per km as a function of how fast you ride and how cold it is, fitted
/// to your rides by weighted least squares. Air drag grows with speed and
/// cold cells deliver less, so both push the rate up.
public struct EfficiencyModel: Equatable, Sendable {
    public let base: Double
    public let perKPH: Double
    public let perDegreeCold: Double
    public let rides: Int

    static let minimumRides = 6
    static let minimumKm = 0.5
    /// Below this, cells start to lose capacity.
    static let comfortableC = 20.0
    /// Pulls slopes toward zero when the rides don't vary enough to pin them
    /// down, like a month of rides at the same temperature.
    static let ridge = 4.0

    /// Nil until there are enough rides with power readings.
    public init?(rides all: [Ride]) {
        let samples = all.compactMap { ride -> (x: SIMD2<Double>, y: Double, weight: Double)? in
            guard ride.distanceKm >= Self.minimumKm, let rate = ride.packWhPerKm else { return nil }
            let cold = max(0, Self.comfortableC - (ride.startTemperatureC ?? Self.comfortableC))
            return (SIMD2(ride.averageMovingKPH, cold), rate, ride.distanceKm)
        }
        guard samples.count >= Self.minimumRides else { return nil }
        let total = samples.reduce(0) { $0 + $1.weight }
        let meanX = samples.reduce(SIMD2<Double>()) { $0 + $1.x * $1.weight } / total
        let meanY = samples.reduce(0) { $0 + $1.y * $1.weight } / total
        // Centred normal equations for the two slopes, then the intercept.
        var sxx = 0.0, sxc = 0.0, scc = 0.0, sxy = 0.0, scy = 0.0
        for sample in samples {
            let d = sample.x - meanX, dy = sample.y - meanY, w = sample.weight / total
            sxx += w * d.x * d.x
            sxc += w * d.x * d.y
            scc += w * d.y * d.y
            sxy += w * d.x * dy
            scy += w * d.y * dy
        }
        let ridge = Self.ridge / total
        sxx += ridge
        scc += ridge
        let determinant = sxx * scc - sxc * sxc
        guard determinant > 0 else { return nil }
        perKPH = (sxy * scc - scy * sxc) / determinant
        perDegreeCold = (scy * sxx - sxy * sxc) / determinant
        base = meanY - perKPH * meanX.x - perDegreeCold * meanX.y
        rides = samples.count
    }

    public func whPerKm(speedKPH: Double, temperatureC: Double?) -> Double {
        let cold = max(0, Self.comfortableC - (temperatureC ?? Self.comfortableC))
        return max(1, base + perKPH * speedKPH + perDegreeCold * cold)
    }
}

/// What your ride history says about how you ride a board.
public struct RideInsights: Equatable, Sendable {
    public let efficiency: EfficiencyModel?
    /// Typical length of a ride, from your recent ones.
    public let usualKm: Double?
    /// Your average moving speed, weighted by distance.
    public let usualKPH: Double?

    static let recentRides = 20
    static let minimumKm = 0.2

    /// `rides` newest first, as the store keeps them.
    public init(rides: [Ride]) {
        efficiency = EfficiencyModel(rides: rides)
        let recent = rides.filter { $0.distanceKm >= Self.minimumKm }.prefix(Self.recentRides)
        let km = recent.map(\.distanceKm).sorted()
        usualKm = km.isEmpty ? nil : km[km.count / 2]
        let moving = recent.reduce(0) { $0 + $1.movingTime }
        usualKPH = moving > 0 ? recent.reduce(0) { $0 + $1.distanceKm } / (moving / 3600) : nil
    }

    /// Wh per km you can expect riding the way you usually do, at the
    /// board's temperature now. Nil until the model has enough rides.
    public func predictedWhPerKm(now t: Telemetry) -> Double? {
        guard let efficiency, let usualKPH else { return nil }
        return efficiency.whPerKm(speedKPH: usualKPH, temperatureC: t.boardTemperatureC)
    }

    /// How many of your usual rides the range covers.
    public func usualRidesLeft(rangeKm: Double) -> Int? {
        guard let usualKm, usualKm > 0 else { return nil }
        return Int(rangeKm / usualKm)
    }
}

/// What past charges say about a board's charger and pack.
public struct ChargeHistory: Equatable, Sendable {
    /// How long one percent usually takes below the jump to 100%.
    public let secondsPerPercent: Double?
    /// Charger energy per percent. Drifting up over months means the pack
    /// is losing capacity, or charging is getting less efficient.
    public let wattHoursPerPercent: Double?

    public init(sessions: [ChargeSession]) {
        secondsPerPercent = Self.median(sessions.compactMap(\.measuredSecondsPerPercent))
        wattHoursPerPercent = Self.median(sessions.compactMap(\.measuredWattHoursPerPercent))
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }
}
