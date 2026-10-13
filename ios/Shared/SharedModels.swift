import ActivityKit
import Foundation

enum AppGroup {
    static let id = "group.sh.dunkirk.unowheel"
    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }
}

/// What the widgets know about the board: the last values the app saw.
struct BoardSnapshot: Codable, Equatable {
    var name: String
    var model: String
    var batteryPercent: Int?
    var voltage: Double?
    var rideMode: String?
    var lifetime: String?
    var range: String?
    var charging: Bool? = nil
    var chargeWatts: Int? = nil
    /// Estimated time the pack will be full, rounded to the minute.
    var fullAt: Date? = nil
    var toppingOff: Bool? = nil
    var lastRide: RideSummary? = nil
    var connected: Bool
    var updatedAt: Date

    /// Serials read better in caps (OW292642); nicknames keep their own case.
    var title: String { name.lowercased().hasPrefix("ow") && name.count > 2 ? name.uppercased() : name }

    private static let key = "boardSnapshot"

    static func load() -> BoardSnapshot? {
        guard let data = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BoardSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.key)
    }

    static let preview = BoardSnapshot(name: "Turbo", model: "Pint", batteryPercent: 72, voltage: nil,
                                       rideMode: "Pacific", lifetime: "412 mi", range: "5.1 mi",
                                       lastRide: RideSummary(topSpeed: 17, unit: "mph", trip: "3.2 mi", minutes: 24, endedAt: .now),
                                       connected: false, updatedAt: .now)

    static let chargingPreview = BoardSnapshot(name: "Turbo", model: "Pint", batteryPercent: 46, voltage: nil,
                                               rideMode: "Pacific", lifetime: "412 mi", range: "3.3 mi",
                                               charging: true, chargeWatts: 170, fullAt: .now.addingTimeInterval(1800),
                                               connected: true, updatedAt: .now)
}

struct RideSummary: Codable, Equatable, Hashable {
    var topSpeed: Int
    var unit: String
    var trip: String
    var minutes: Int
    var endedAt: Date
}

enum RideState: String, Codable, Hashable {
    case riding, braking, stopped, charging

    var label: String {
        switch self {
        case .riding: "Riding"
        case .braking: "Regen"
        case .stopped: "Stopped"
        case .charging: "Charging"
        }
    }

    var symbol: String {
        switch self {
        case .riding: "figure.skateboarding"
        case .braking: "arrow.uturn.backward"
        case .stopped: "pause.circle"
        case .charging: "bolt.fill"
        }
    }
}

struct RideAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speed: Int
        var unit: String
        var batteryPercent: Int
        var rideMode: String
        var trip: String
        var range: String
        var rangeLearned: Bool
        var state: RideState
        var topSpeed: Int
        /// Full-scale value for the speedometer arc.
        var speedMax: Int = 20
        var chargeWatts: Int = 0
        var fullAt: Date? = nil
        var toppingOff: Bool = false
    }

    var boardName: String
    var startedAt: Date
}
