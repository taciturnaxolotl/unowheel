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

    static let preview = BoardSnapshot(name: "ow292642", model: "Pint", batteryPercent: 72, voltage: 58.4,
                                       rideMode: "Pacific", lifetime: "412 mi", range: "5 mi", connected: false, updatedAt: .now)
}

enum RideState: String, Codable, Hashable {
    case riding, braking, stopped

    var label: String {
        switch self {
        case .riding: "Riding"
        case .braking: "Regen"
        case .stopped: "Stopped"
        }
    }

    var symbol: String {
        switch self {
        case .riding: "figure.skateboarding"
        case .braking: "arrow.uturn.backward"
        case .stopped: "pause.circle"
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
    }

    var boardName: String
    var startedAt: Date
}
