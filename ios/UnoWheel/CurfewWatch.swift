import CoreLocation
import MapKit
import Observation
import OnewheelKit

/// Feeds the ride's position to the curfew and sounds its warnings.
@MainActor
@Observable
final class CurfewWatch {
    private(set) var settings: Curfew
    private(set) var status: Curfew.Status?
    @ObservationIgnored private var route: (Curfew.Route, at: Date)?
    @ObservationIgnored private var routing = false
    @ObservationIgnored private var sounded: Set<Curfew.Warning> = []
    @ObservationIgnored private let alert = CurfewAlert()
    @ObservationIgnored var log: (String) -> Void = { _ in } {
        didSet { alert.log = log }
    }

    private static let key = "curfew"
    /// Directions are refreshed this often, or after this far.
    private static let routeFreshness: TimeInterval = 15
    private static let routeDistance = 25.0

    init() {
        settings = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Curfew.self, from: $0) } ?? Curfew()
    }

    func save(_ settings: Curfew) {
        self.settings = settings
        UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.key)
        route = nil
        if settings.enabled { Task { await alert.requestPermission() } }
    }

    /// Call once a second with the ride's latest fix; nil when no ride is on.
    func update(location: CLLocation?, now: Date = .now) {
        guard let location else {
            route = nil
            rearm(showing: nil)
            return
        }
        let here = Curfew.Place(location)
        guard let status = settings.status(at: here, route: route?.0, now: now) else {
            rearm(showing: nil)
            return
        }
        self.status = status
        refreshRoute(from: here, now: now)
        if let warning = status.warning, sounded.insert(warning).inserted {
            Task { await alert.sound(status) }
        } else if status.hasSlack {
            rearm(showing: status)
        }
    }

    /// Re-arms the warnings and stops any alarm, leaving `status` as given.
    private func rearm(showing status: Curfew.Status?) {
        self.status = status
        sounded = []
        alert.silence()
    }

    private func refreshRoute(from here: Curfew.Place, now: Date) {
        guard !routing, let home = settings.home else { return }
        if let (cached, at) = route, now.timeIntervalSince(at) < Self.routeFreshness,
           here.meters(to: cached.from) < Self.routeDistance { return }
        routing = true
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: home.coordinate))
        request.transportType = .walking
        Task {
            defer { routing = false }
            do {
                if let found = try await MKDirections(request: request).calculate().routes.first {
                    route = (Curfew.Route(meters: found.distance, from: here), now)
                }
            } catch {
                if route == nil { log("curfew: no directions, assuming a typical detour: \(error.localizedDescription)") }
            }
        }
    }
}

extension Curfew.Place {
    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
