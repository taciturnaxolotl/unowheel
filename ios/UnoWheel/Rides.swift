import CoreLocation
import Foundation
import Observation
import OnewheelKit

/// Rides saved as one JSON file each, newest first. Files keep the raw
/// GPS; `rides` holds cleaned routes, so the cleanup can be retuned later.
@MainActor
@Observable
final class RideStore {
    private(set) var rides: [Ride] = [] {
        didSet { insights = Dictionary(grouping: rides) { $0.board.lowercased() }.mapValues(RideInsights.init) }
    }
    private var insights: [String: RideInsights] = [:]

    private let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "rides", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init() {
        reload()
        Task { await annotate() }
    }

    func insights(for board: String?) -> RideInsights? {
        board.flatMap { insights[$0.lowercased()] }
    }

    func rename(_ ride: Ride, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        update(ride.id) { $0.customTitle = trimmed.isEmpty ? nil : trimmed }
    }

    /// Looks up where rides started and ended, for their titles, and the
    /// weather they started in. Apple rate-limits geocoding, so this goes
    /// one ride at a time.
    func annotate() async {
        for ride in rides where ride.hasRoute {
            let first = ride.points.first(where: \.hasLocation)
            if ride.startPlace == nil, let start = await Self.place(for: first) {
                let end = await Self.place(for: ride.points.last(where: \.hasLocation))
                update(ride.id) {
                    $0.startPlace = start
                    $0.endPlace = end
                }
            }
            if ride.weather == nil, let coordinate = first?.coordinate,
               let weather = await WeatherLookup.weather(at: coordinate, on: ride.startedAt) {
                update(ride.id) { $0.weather = weather }
            }
        }
    }

    /// The most specific useful name: a park or landmark, then the
    /// neighbourhood, then the town.
    private static func place(for point: RidePoint?) async -> String? {
        guard let lat = point?.latitude, let lon = point?.longitude else { return nil }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first
        return placemark?.areasOfInterest?.first ?? placemark?.subLocality ?? placemark?.locality
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        rides = files.compactMap(Self.read).map { $0.cleanedRoute() }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Saves a ride as recorded.
    func save(_ ride: Ride) {
        guard let data = try? JSONEncoder().encode(ride) else { return }
        try? data.write(to: file(for: ride.id), options: .atomic)
        rides.removeAll { $0.id == ride.id }
        rides.append(ride.cleanedRoute())
        rides.sort { $0.startedAt > $1.startedAt }
    }

    /// Edits the saved raw ride, not the cleaned copy in `rides`.
    private func update(_ id: UUID, _ change: (inout Ride) -> Void) {
        guard var ride = Self.read(file(for: id)) else { return }
        change(&ride)
        save(ride)
    }

    private static func read(_ url: URL) -> Ride? {
        try? JSONDecoder().decode(Ride.self, from: Data(contentsOf: url))
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
    /// After you end a ride by hand, wait for the board to stop before
    /// starting another, so it doesn't restart mid-roll.
    private var holdUntilStopped = false
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
        manager.distanceFilter = kCLDistanceFilterNone
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

    /// Call once a second with the latest board state. `volts` is the pack
    /// voltage, worked out when the board doesn't report it.
    func update(board: String?, telemetry t: Telemetry, volts: Double?, live: Bool, now: Date = .now) {
        guard live, let board, !t.isCharging else {
            if current != nil { finish() }
            return
        }
        // Called from both the 1 s timer and board notifications; keep one
        // sample per second.
        guard now.timeIntervalSince(lastSample) >= 0.9 else { return }
        lastSample = now
        let speed = t.speedKPH ?? 0
        if speed >= Ride.movingKPH { lastMoving = now } else { holdUntilStopped = false }

        if current == nil {
            guard speed >= 3, !holdUntilStopped else { return }
            start(board: board, telemetry: t, now: now)
        }
        guard var ride = current else { return }
        // Each fix is used once: indoors no new fixes arrive, and repeating
        // the last one pins the route to a doorway.
        let location = lastLocation.flatMap { now.timeIntervalSince($0.timestamp) < 3 ? $0 : nil }
        lastLocation = nil
        ride.points.append(RidePoint(time: now,
                                     latitude: location?.coordinate.latitude,
                                     longitude: location?.coordinate.longitude,
                                     altitude: location?.altitude,
                                     speedKPH: speed,
                                     batteryPercent: t.batteryPercent,
                                     watts: t.motorWatts,
                                     motorTempC: t.motorTemperatureC,
                                     controllerTempC: t.controllerTemperatureC,
                                     batteryTempC: t.batteryTemperatureC,
                                     volts: volts))
        // The trip counter can arrive a moment after the ride starts.
        if tripStart == nil { tripStart = t.tripRevolutions }
        if let start = tripStart, let trip = t.tripRevolutions, trip >= start {
            ride.odometerKm = Double(trip - start) * t.model.wheelCircumferenceMM / 1_000_000
        }
        current = ride
        if now.timeIntervalSince(lastMoving) > Self.stopTimeout { finish() }
    }

    /// Ends the current ride now. Discarding throws it away.
    func end(save: Bool) {
        holdUntilStopped = true
        if save {
            finish()
        } else {
            stopLocation()
            current = nil
            log("ride discarded")
        }
    }

    func finish() {
        stopLocation()
        guard var ride = current else { return }
        current = nil
        // Drop the idle tail after the last movement.
        if let lastMove = ride.points.lastIndex(where: { $0.speedKPH >= Ride.movingKPH }) {
            ride.points = Array(ride.points.prefix(through: min(lastMove + 1, ride.points.count - 1)))
        }
        let cleaned = ride.cleanedRoute()
        guard cleaned.isWorthSaving else {
            log("ride too short, not saved")
            return
        }
        store.save(ride)
        log(String(format: "ride saved: %.2f km", cleaned.distanceKm))
        Task { await store.annotate() }
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
        // Indoors and just after stepping outside, fixes come back with poor
        // accuracy; only trust ones within 20 m.
        guard let latest = locations.last, latest.horizontalAccuracy >= 0, latest.horizontalAccuracy <= 20 else { return }
        lastLocation = latest
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if isRecording, status == .authorizedWhenInUse || status == .authorizedAlways {
            startLocation()
        }
    }
}
