import Foundation
import Testing
@testable import OnewheelKit

@Suite struct CurfewTests {
    static let eastern: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static func date(_ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        eastern.date(from: DateComponents(year: 2026, month: m, day: d, hour: h, minute: min, second: s))!
    }

    static let carr = Curfew.Place(latitude: 39.74581, longitude: -83.81203, name: "Carr Hall")
    /// The engineering building's bike rack, 387 m from Carr as the crow flies.
    static let engineering = Curfew.Place(latitude: 39.74925, longitude: -83.81135)
    /// Downtown South Charleston, where a Saturday ride went.
    static let southCharleston = Curfew.Place(latitude: 39.79770, longitude: -83.69490)
    static let on = Curfew(enabled: true, home: carr)

    @Test func weeknightDeadlineIsMidnight() {
        #expect(Curfew().nextDeadline(after: Self.date(10, 26, 23, 47), calendar: Self.eastern) == Self.date(10, 27, 0, 0))
    }

    @Test func weekendDeadlineRunsPastMidnight() {
        let curfew = Curfew()
        #expect(curfew.nextDeadline(after: Self.date(10, 24, 0, 44), calendar: Self.eastern) == Self.date(10, 24, 1, 0))
        #expect(curfew.nextDeadline(after: Self.date(10, 24, 1, 1), calendar: Self.eastern) == Self.date(10, 25, 1, 0))
    }

    @Test func nightsWithoutCurfewAreSkipped() {
        var curfew = Curfew()
        curfew.minutesByWeekday[7] = nil
        #expect(curfew.nextDeadline(after: Self.date(10, 24, 19, 0), calendar: Self.eastern) == Self.date(10, 26, 0, 0))
        #expect(Curfew(minutesByWeekday: [:]).nextDeadline(after: .now) == nil)
    }

    @Test func watchesOnlyOnCampusNearCurfew() {
        func watching(_ curfew: Curfew, _ here: Curfew.Place, _ now: Date) -> Bool {
            curfew.status(at: here, route: nil, now: now, calendar: Self.eastern) != nil
        }
        let late = Self.date(10, 26, 23, 50)
        #expect(watching(Self.on, Self.engineering, late))
        #expect(!watching(Self.on, Self.southCharleston, late))
        #expect(!watching(Self.on, Self.engineering, Self.date(10, 26, 21, 0)))
        #expect(!watching(Curfew(enabled: false, home: Self.carr), Self.engineering, late))
        #expect(!watching(Curfew(enabled: true), Self.engineering, late))
    }

    @Test func rideHomeMatchesRecordedLegs() {
        // 1,000 m by route took 238 s; the 455 m hop from engineering took 73 to 111 s.
        let far = HomewardEstimate.seconds(routeMeters: 1000)
        #expect(far > 238 && far < 320)
        let hop = HomewardEstimate.seconds(routeMeters: 455)
        #expect(hop > 111 && hop < 160)
    }

    @Test func routeIsNeverTrustedBelowATypicalDetour() {
        let line = Self.engineering.meters(to: Self.carr)
        #expect(abs(line - 387) < 10)
        #expect(HomewardEstimate.routeMeters(from: Self.engineering, to: Self.carr, route: nil) == line * 1.45)
        let short = Curfew.Route(meters: 400, from: Self.engineering)
        #expect(HomewardEstimate.routeMeters(from: Self.engineering, to: Self.carr, route: short) == line * 1.45)
    }

    @Test func staleRouteChargesForRidingAway() {
        let route = Curfew.Route(meters: 2000, from: Self.engineering)
        let away = Curfew.Place(latitude: Self.engineering.latitude + 0.0003, longitude: Self.engineering.longitude)
        let moved = away.meters(to: Self.engineering)
        #expect(abs(HomewardEstimate.routeMeters(from: away, to: Self.carr, route: route) - (2000 + moved)) < 0.001)
    }

    @Test func warningsEscalate() throws {
        let route = Curfew.Route(meters: 1000, from: Self.engineering)
        func status(_ minute: Int) throws -> Curfew.Status {
            try #require(Self.on.status(at: Self.engineering, route: route, now: Self.date(10, 26, 23, minute), calendar: Self.eastern))
        }
        // Ride home is 287 s, buffer 120 s: leave by 23:53:13.
        #expect(try status(50).warning == nil)
        #expect(try status(50).hasSlack)
        #expect(abs(try status(50).secondsToSpare - (600 - 287.14 - 120)) < 1)
        #expect(try status(54).warning == .leave)
        #expect(try status(56).warning == .late)
        #expect(try status(56).rideMinutes == 5)
    }

    @Test func roundTripsThroughJSON() throws {
        let curfew = Curfew(enabled: true, home: Self.carr, bufferSeconds: 90)
        #expect(try JSONDecoder().decode(Curfew.self, from: JSONEncoder().encode(curfew)) == curfew)
    }
}
