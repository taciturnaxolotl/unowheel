import Foundation

/// Where you sleep, when you have to be back, and when a ride should turn for home.
public struct Curfew: Codable, Equatable, Sendable {
    public struct Place: Codable, Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public var name: String?

        public init(latitude: Double, longitude: Double, name: String? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.name = name
        }

        public func meters(to other: Place) -> Double {
            greatCircleMeters(latitude, longitude, other.latitude, other.longitude)
        }
    }

    /// A route length home, and where it was measured from.
    public struct Route: Equatable, Sendable {
        public var meters: Double
        public var from: Place

        public init(meters: Double, from: Place) {
            self.meters = meters
            self.from = from
        }
    }

    public enum Warning: Sendable { case leave, late }

    public var enabled = false
    public var home: Place?
    /// Minutes after midnight, keyed by `Calendar` weekday (1 is Sunday); past
    /// 1440 is the next morning. A missing day has no curfew.
    public var minutesByWeekday: [Int: Int]
    public var bufferSeconds: TimeInterval

    /// Midnight Sunday to Thursday nights, 1 am after Friday and Saturday.
    public static let defaultMinutes: [Int: Int] = [1: 1440, 2: 1440, 3: 1440, 4: 1440, 5: 1440, 6: 1500, 7: 1500]
    /// Farther than this from home you're off campus, and curfew isn't the point.
    public static let campusRadiusMeters = 1500.0
    /// Nothing is worth saying earlier than this before curfew.
    public static let watchWindow: TimeInterval = 90 * 60

    public init(enabled: Bool = false, home: Place? = nil,
                minutesByWeekday: [Int: Int] = Curfew.defaultMinutes, bufferSeconds: TimeInterval = 120) {
        self.enabled = enabled
        self.home = home
        self.minutesByWeekday = minutesByWeekday
        self.bufferSeconds = bufferSeconds
    }

    /// The first curfew after `now`; in the small hours that's still last night's.
    public func nextDeadline(after now: Date, calendar: Calendar = .current) -> Date? {
        (-1...1).compactMap { offset -> Date? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let start = calendar.startOfDay(for: day)
            guard let minutes = minutesByWeekday[calendar.component(.weekday, from: start)] else { return nil }
            return calendar.date(byAdding: .minute, value: minutes, to: start)
        }
        .filter { $0 > now }
        .min()
    }

    /// Where a ride at `here` stands, or nil off campus, with curfew still far off, or switched off.
    public func status(at here: Place, route: Route?, now: Date, calendar: Calendar = .current) -> Status? {
        guard enabled, let home, home.meters(to: here) <= Self.campusRadiusMeters,
              let deadline = nextDeadline(after: now, calendar: calendar),
              deadline.timeIntervalSince(now) <= Self.watchWindow else { return nil }
        let ride = HomewardEstimate.seconds(routeMeters: HomewardEstimate.routeMeters(from: here, to: home, route: route))
        return Status(home: home, deadline: deadline, rideSeconds: ride,
                      leaveBy: deadline.addingTimeInterval(-(ride + bufferSeconds)), now: now)
    }

    public struct Status: Equatable, Sendable {
        public let home: Place
        public let deadline: Date
        public let rideSeconds: TimeInterval
        /// Latest moment to turn for home and still arrive with the buffer.
        public let leaveBy: Date
        public let now: Date

        public var secondsToSpare: TimeInterval { leaveBy.timeIntervalSince(now) }
        public var rideMinutes: Int { max(1, Int((rideSeconds / 60).rounded(.up))) }

        public var warning: Warning? {
            if now.addingTimeInterval(rideSeconds) > deadline { return .late }
            return secondsToSpare <= 0 ? .leave : nil
        }

        /// A clear minute in hand; warnings may fire again if you wander back out.
        public var hasSlack: Bool { secondsToSpare > 60 }
    }
}

/// Door-to-door time home, fitted to 1,341 homeward samples over nine rides to
/// the dorm: late once by 19 s, otherwise early by 40 to 60 s.
public enum HomewardEstimate {
    public static let overheadSeconds: TimeInterval = 30
    /// About the 10th percentile of door-to-door speed by shortest route.
    public static let speedKPH = 14.0
    /// 90th percentile of route length over straight-line distance on campus.
    public static let detourFactor = 1.45

    public static func seconds(routeMeters: Double) -> TimeInterval {
        overheadSeconds + max(0, routeMeters) / (speedKPH / 3.6)
    }

    /// A route can go stale as you ride; charge for the distance since it was
    /// measured, and never trust less than a typical detour over the straight line.
    public static func routeMeters(from here: Curfew.Place, to home: Curfew.Place, route: Curfew.Route?) -> Double {
        let pessimistic = here.meters(to: home) * detourFactor
        guard let route else { return pessimistic }
        return max(route.meters + here.meters(to: route.from), pessimistic)
    }
}
