import CoreLocation
import Foundation
import Observation
import OnewheelKit

/// Rides saved as one JSON file each, newest first.
@MainActor
@Observable
final class RideStore {
    private(set) var rides: [Ride] = []

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "rides", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        rides = files.compactMap { try? JSONDecoder().decode(Ride.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ ride: Ride) {
        guard let data = try? JSONEncoder().encode(ride) else { return }
        try? data.write(to: file(for: ride.id), options: .atomic)
        rides.removeAll { $0.id == ride.id }
        rides.insert(ride, at: 0)
        rides.sort { $0.startedAt > $1.startedAt }
    }

    func delete(_ ride: Ride) {
        try? FileManager.default.removeItem(at: file(for: ride.id))
        rides.removeAll { $0.id == ride.id }
    }

    func rides(for board: String?) -> [Ride] {
        guard let board else { return rides }
        return rides.filter { $0.board.lowercased() == board.lowercased() }
    }

    private func file(for id: UUID) -> URL { folder.appending(path: "\(id.uuidString).json") }
}

/// Starts a ride when the board starts moving, samples GPS and board data
/// every second, and saves it when the board stops for a while or drops.
@MainActor
final class RideRecorder: NSObject {
    let store: RideStore
    var log: (String) -> Void = { _ in }

    private(set) var current: Ride?
    private var tripStart: Int?
    private var lastMoving = Date.distantPast
    private var lastLocation: CLLocation?
    private var lastSample = Date.distantPast
    private let manager = CLLocationManager()
    private var backgroundSession: CLBackgroundActivitySession?
    private var updating = false

    /// How long the board can sit still before the ride ends.
    static let stopTimeout: TimeInterval = 5 * 60

    init(store: RideStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
    }

    var isRecording: Bool { current != nil }

    /// Ask on the board screen, not mid-ride when the prompt can't be tapped.
    func requestPermissionIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    /// Call once a second with the latest board state.
    func update(board: String?, telemetry t: Telemetry, live: Bool, now: Date = .now) {
        guard live, let board, !t.isCharging else {
            if current != nil { finish() }
            return
        }
        // Called from both the 1 s timer and board notifications; keep one
        // sample per second.
        guard now.timeIntervalSince(lastSample) >= 0.9 else { return }
        lastSample = now
        let speed = t.speedKPH ?? 0
        if speed >= 2 { lastMoving = now }

        if current == nil {
            guard speed >= 3 else { return }
            start(board: board, telemetry: t, now: now)
        }
        guard var ride = current else { return }
        let location = lastLocation.flatMap { now.timeIntervalSince($0.timestamp) < 5 ? $0 : nil }
        ride.points.append(RidePoint(time: now,
                                     latitude: location?.coordinate.latitude,
                                     longitude: location?.coordinate.longitude,
                                     altitude: location?.altitude,
                                     speedKPH: speed,
                                     batteryPercent: t.batteryPercent))
        if let start = tripStart, let trip = t.tripRevolutions, trip >= start {
            ride.odometerKm = Double(trip - start) * t.model.wheelCircumferenceMM / 1_000_000
        }
        current = ride
        if now.timeIntervalSince(lastMoving) > Self.stopTimeout { finish() }
    }

    func finish() {
        stopLocation()
        guard var ride = current else { return }
        current = nil
        // Drop the idle tail after the last movement.
        if let lastMove = ride.points.lastIndex(where: { $0.speedKPH >= 2 }) {
            ride.points = Array(ride.points.prefix(through: min(lastMove + 1, ride.points.count - 1)))
        }
        guard ride.isWorthSaving else {
            log("ride too short, not saved")
            return
        }
        store.save(ride)
        log(String(format: "ride saved: %.2f km", ride.distanceKm))
    }

    private func start(board: String, telemetry t: Telemetry, now: Date) {
        current = Ride(board: board)
        tripStart = t.tripRevolutions
        lastMoving = now
        log("ride started")
        startLocation()
    }

    private func startLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // Starts once you answer, via the authorization callback.
            manager.requestWhenInUseAuthorization()
            return
        case .authorizedWhenInUse:
            // Always lets a ride that starts with the phone locked get a map.
            // iOS shows this upgrade prompt once.
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            log("location off, recording without a map")
            return
        default:
            break
        }
        guard !updating else { return }
        updating = true
        // With Always access location can start in the background; the
        // session covers While Using, where it must start in the foreground.
        if manager.authorizationStatus == .authorizedWhenInUse {
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
    }

    private func stopLocation() {
        updating = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        lastLocation = nil
    }
}

extension RideRecorder: @preconcurrency CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0, latest.horizontalAccuracy < 50 else { return }
        lastLocation = latest
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if isRecording, status == .authorizedWhenInUse || status == .authorizedAlways {
            startLocation()
        }
    }
}
