import Foundation
import Observation
import OnewheelKit

/// Follows charging and keeps every session on disk, one JSON file each,
/// so charge time and pack health can be learned per board.
@MainActor
@Observable
final class ChargeRecorder {
    var current: ChargeSession?
    @ObservationIgnored private var savedSamples = 0

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "charges", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Call once a second while connected. A session ends when the board
    /// stops charging; readings only count while `live`.
    func update(board: String?, telemetry t: Telemetry, volts: Double?, live: Bool) {
        guard t.isCharging else {
            current = nil
            return
        }
        guard live, let percent = t.batteryPercent else { return }
        if current == nil {
            current = ChargeSession(board: board, typicalSecondsPerPercent: history(for: board).secondsPerPercent)
            savedSamples = 0
        }
        current?.record(percent: percent, watts: t.chargingWatts, volts: volts, batteryTempC: t.batteryTemperatureC)
        // Saved as it goes, so a charge isn't lost if the app is closed.
        if let current, current.samples.count != savedSamples {
            savedSamples = current.samples.count
            guard let data = try? JSONEncoder().encode(current) else { return }
            try? data.write(to: folder.appending(path: "\(current.id.uuidString).json"), options: .atomic)
        }
    }

    func history(for board: String?) -> ChargeHistory {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let sessions = files.compactMap { try? JSONDecoder().decode(ChargeSession.self, from: Data(contentsOf: $0)) }
        return ChargeHistory(sessions: sessions.filter { $0.board?.lowercased() == board?.lowercased() })
    }
}
