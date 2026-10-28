import Foundation
import OnewheelKit

// Usage: swift run ridestats [pull folder] [--since YYYY-MM-DD] [--ride ID-prefix]
// Prints every ride the way the app sees it: cleaned with OnewheelKit, not raw JSON.

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(i...(i + 1)) }
    return arguments[i + 1]
}
let since = option("--since").flatMap { ISO8601DateFormatter().date(from: $0 + "T00:00:00Z") }
let only = option("--ride")
let folder = URL(fileURLWithPath: arguments.first ?? "/tmp/unowheel-pull")

@MainActor func load<T: Decodable>(_ type: T.Type, in name: String) -> [T] {
    let dir = folder.appending(path: name)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(T.self, from: Data(contentsOf: $0)) }
}

let local = DateFormatter()
local.dateFormat = "EEE MMM d HH:mm"
func f(_ value: Double?, _ format: String = "%.1f") -> String { value.map { String(format: format, $0) } ?? "-" }

let raw = load(Ride.self, in: "rides").sorted { $0.startedAt < $1.startedAt }
let rides = raw.filter { ride in
    (since.map { ride.startedAt >= $0 } ?? true) && (only.map { ride.id.uuidString.hasPrefix($0.uppercased()) } ?? true)
}
print("\(rides.count) of \(raw.count) rides\n")
print("when                 id        km    top  avg  moving  fixes     route       Wh/km  start°C  air°C  pushback  title")
for ride in rides {
    let c = ride.cleanedRoute()
    let fixes = "\(ride.points.filter(\.hasLocation).count)->\(c.points.filter(\.hasLocation).count)"
    print([
        local.string(from: ride.startedAt).padding(toLength: 20, withPad: " ", startingAt: 0),
        String(ride.id.uuidString.prefix(8)),
        f(c.distanceKm, "%5.2f"), f(c.topSpeedKPH, "%5.1f"), f(c.averageMovingKPH, "%4.1f"),
        String(format: "%5.0fs", c.movingTime), fixes.padding(toLength: 9, withPad: " ", startingAt: 0),
        "\(c.routeQuality)".padding(toLength: 11, withPad: " ", startingAt: 0),
        f(c.packWhPerKm, "%5.1f"), f(c.startTemperatureC, "%7.0f"), f(c.weather?.temperatureC, "%6.0f"),
        f(c.pushbackKPH, "%8.1f"), c.title(),
    ].joined(separator: "  "))
}

let cleaned = raw.map { $0.cleanedRoute() }.reversed()
for board in Set(cleaned.map { $0.board.lowercased() }).sorted() {
    let insights = RideInsights(rides: cleaned.filter { $0.board.lowercased() == board })
    print("\n\(board): usual ride \(f(insights.usualKm, "%.2f")) km at \(f(insights.usualKPH)) km/h")
    if let model = insights.efficiency {
        print("  Wh/km = \(f(model.base, "%.2f")) + \(f(model.perKPH, "%.3f"))/kmh + \(f(model.perDegreeCold, "%.3f"))/°C below 20, from \(model.rides) rides")
    } else {
        print("  efficiency model: not enough rides yet")
    }
}

let charges = load(ChargeSession.self, in: "charges").sorted { $0.startedAt < $1.startedAt }
if !charges.isEmpty {
    print("\ncharges")
    for charge in charges where !charge.samples.isEmpty {
        let minutes = (charge.samples.last!.date.timeIntervalSince(charge.samples.first!.date)) / 60
        print("  \(local.string(from: charge.startedAt))  \(charge.startPercent ?? 0)% -> \(charge.latestPercent ?? 0)%  \(f(minutes, "%.0f")) min  avg \(f(charge.averageWatts, "%.0f")) W")
    }
}
