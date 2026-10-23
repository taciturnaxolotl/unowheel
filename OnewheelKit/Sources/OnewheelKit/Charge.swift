import Foundation

/// Follows one charging session and estimates when the board will say 100%.
///
/// Measured on a 5208 Pint: the charger holds about 3.1 A (190 W) and the
/// percentage climbs linearly at about 28 s per point. At about 88% the
/// pack reaches 63 V (4.2 V per cell), the charger switches to constant
/// voltage, and the board jumps straight to 99-100%. It keeps charging
/// for 30+ minutes after that while the power tapers from ~150 W to ~20 W.
/// So "100%" arrives at the start of the taper. The estimate stops at the
/// jump, which is also when the board passes 90%: past that point the cells
/// gain little for a lot of waiting.
public struct ChargeSession: Codable, Equatable, Sendable, Identifiable {
    public struct Sample: Codable, Equatable, Sendable, Identifiable {
        public let date: Date
        public let percent: Int
        public let watts: Double?
        public var volts: Double?
        public var batteryTempC: Int?
        public var id: Date { date }
    }

    public private(set) var samples: [Sample] = []
    public let id: UUID
    public let startedAt: Date
    public let board: String?
    /// How long a percent took on this board's past charges, used until
    /// this session has measured its own rate.
    public let typicalSecondsPerPercent: Double?

    /// Percent change needed before the measured rate replaces the power guess.
    static let minimumMeasuredPoints = 3
    /// Where the board stops counting up and jumps to 100%.
    static let jumpPercent = 88

    public init(id: UUID = UUID(), startedAt: Date = .now, board: String? = nil, typicalSecondsPerPercent: Double? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.board = board
        self.typicalSecondsPerPercent = typicalSecondsPerPercent
    }

    public var startPercent: Int? { samples.first?.percent }
    public var latestPercent: Int? { samples.last?.percent }

    /// Records a reading, keeping at most one sample every 30 seconds unless
    /// the percentage changed.
    public mutating func record(percent: Int, watts: Double?, volts: Double? = nil, batteryTempC: Int? = nil,
                                at date: Date = .now) {
        if let last = samples.last, last.percent == percent, date.timeIntervalSince(last.date) < 30 { return }
        samples.append(Sample(date: date, percent: percent, watts: watts, volts: volts, batteryTempC: batteryTempC))
    }

    /// Samples where the percentage changed. Measuring between these avoids
    /// skew from a session that starts partway through a percent.
    var steps: [Sample] {
        zip(samples.dropFirst(), samples).filter { $0.percent != $1.percent }.map(\.0)
    }

    var measuredSecondsPerPercent: Double? {
        let steps = steps
        guard let first = steps.first, let last = steps.last else { return nil }
        let points = last.percent - first.percent
        guard points >= Self.minimumMeasuredPoints else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        return span > 0 ? span / Double(points) : nil
    }

    /// Charger energy per percent, between the first and last steps below
    /// the jump.
    var measuredWattHoursPerPercent: Double? {
        let steps = steps.filter { $0.percent < Self.jumpPercent }
        guard let first = steps.first, let last = steps.last,
              last.percent - first.percent >= Self.minimumMeasuredPoints else { return nil }
        let span = samples.filter { $0.date >= first.date && $0.date <= last.date }
        let wh = zip(span, span.dropFirst()).reduce(0.0) { total, pair in
            guard let watts = pair.0.watts else { return total }
            return total + watts * pair.1.date.timeIntervalSince(pair.0.date) / 3600
        }
        return wh > 0 ? wh / Double(last.percent - first.percent) : nil
    }

    public var isMeasured: Bool { measuredSecondsPerPercent != nil }

    /// Past the jump the board reads 99-100% while the charger tapers.
    /// Charge power gets small and noisy there, so the percentage alone
    /// decides; the charging bit says whether the charger is still on.
    public static func isToppingOff(percent: Int?, watts: Double? = nil) -> Bool {
        (percent ?? 0) >= jumpPercent
    }

    /// Average charge power over the session.
    public var averageWatts: Double? {
        let watts = samples.compactMap(\.watts)
        guard !watts.isEmpty else { return nil }
        return watts.reduce(0, +) / Double(watts.count)
    }

    public func secondsToFull(packWattHours: Double) -> TimeInterval? {
        guard let percent = latestPercent, percent < Self.jumpPercent else { return nil }
        let perPercent: Double
        if let measured = measuredSecondsPerPercent ?? typicalSecondsPerPercent {
            perPercent = measured
        } else if let watts = samples.last?.watts ?? averageWatts, watts > 20 {
            perPercent = packWattHours / 100 / watts * 3600
        } else {
            return nil
        }
        return Double(max(1, Self.jumpPercent - percent)) * perPercent
    }
}
