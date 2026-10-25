import MapKit
import OnewheelKit
import SwiftUI

/// The whole heatmap as one map overlay. MapKit draws it in tiles on
/// background threads and only asks for what is on screen, so it holds up
/// with hundreds of rides.
final class HeatmapOverlay: NSObject, MKOverlay, @unchecked Sendable {
    let tracks: [HeatRaster.Track]
    let palette: HeatRaster.Palette
    let boundingMapRect: MKMapRect
    var isEmpty: Bool { tracks.isEmpty }

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    init(rides: [Ride]) {
        // A raw indoor track is a scribble that would glow like a busy path.
        tracks = rides.filter { $0.routeQuality != .lowSignal }.compactMap { HeatRaster.Track(ride: $0) }
        palette = HeatRaster.Palette(brightest: tracks.count)
        boundingMapRect = tracks.reduce(MKMapRect.null) { $0.union($1.rect) }
    }
}

final class HeatmapRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? HeatmapOverlay else { return }
        let pixelsPerMapPoint = Double(zoomScale) * Double(contentScaleFactor)
        let width = Int((mapRect.width * pixelsPerMapPoint).rounded(.up))
        let height = Int((mapRect.height * pixelsPerMapPoint).rounded(.up))
        let drawn = MKMapRect(x: mapRect.minX, y: mapRect.minY,
                              width: Double(width) / pixelsPerMapPoint, height: Double(height) / pixelsPerMapPoint)
        guard let image = HeatRaster.image(tracks: overlay.tracks, palette: overlay.palette, mapRect: drawn,
                                           width: width, height: height, zoomScale: Double(zoomScale))
        else { return }
        UIGraphicsPushContext(context)
        UIImage(cgImage: image).draw(in: rect(for: drawn))
        UIGraphicsPopContext()
    }
}

/// MKMapView host for the heatmap. Opens on your location; if that isn't
/// available it fits every ride.
struct HeatmapMapView: UIViewRepresentable {
    let overlay: HeatmapOverlay?
    var interactive = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.overrideUserInterfaceStyle = .dark
        map.showsUserLocation = true
        map.showsCompass = interactive
        if interactive {
            let button = MKUserTrackingButton(mapView: map)
            button.backgroundColor = .secondarySystemBackground.withAlphaComponent(0.9)
            button.layer.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            map.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            ])
            map.layoutMargins.top = 56
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.show(overlay, on: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private enum Placement { case none, onRides, onUser }

        private var shown: HeatmapOverlay?
        private var placement = Placement.none

        /// Rides within this distance of you decide the opening view, which
        /// spans between `minSpan` and `maxSpan`.
        private let nearby: CLLocationDistance = 1500
        private let minSpan: CLLocationDistance = 400
        private let maxSpan: CLLocationDistance = 3000

        func show(_ overlay: HeatmapOverlay?, on map: MKMapView) {
            guard overlay !== shown else { return }
            if let shown { map.removeOverlay(shown) }
            shown = overlay
            guard let overlay, !overlay.isEmpty else { return }
            map.addOverlay(overlay, level: .aboveRoads)
            place(map)
        }

        func mapView(_ map: MKMapView, didUpdate userLocation: MKUserLocation) {
            place(map)
        }

        /// Opens on the rides around you, up to 3 km across. With no rides
        /// near you it fits every ride; before your location is known it
        /// fits every ride and moves once the location arrives.
        private func place(_ map: MKMapView) {
            guard placement != .onUser, let overlay = shown else { return }
            let padding = UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30)
            guard let location = map.userLocation.location else {
                if placement == .none {
                    placement = .onRides
                    map.setVisibleMapRect(overlay.boundingMapRect, edgePadding: padding, animated: false)
                }
                return
            }
            let animated = placement == .onRides
            placement = .onUser
            let here = MKMapPoint(location.coordinate)
            let close = overlay.tracks.lazy.flatMap(\.points).filter { $0.distance(to: here) <= self.nearby }
            guard close.first != nil else {
                map.setVisibleMapRect(overlay.boundingMapRect, edgePadding: padding, animated: animated)
                return
            }
            let rect = MKMapRect(enclosing: [here] + close)
            let perMetre = MKMapPointsPerMeterAtLatitude(location.coordinate.latitude)
            func clamp(_ span: Double) -> Double { min(max(span, minSpan * perMetre), maxSpan * perMetre) }
            let width = clamp(rect.width), height = clamp(rect.height)
            let fitted = MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
            map.setVisibleMapRect(fitted, edgePadding: padding, animated: animated)
        }

        func mapView(_ map: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if overlay is HeatmapOverlay { return HeatmapRenderer(overlay: overlay) }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

extension HeatRaster.Track {
    /// The ride's smoothed route in map points.
    init?(ride: Ride) {
        self.init(points: ride.smoothed().points.compactMap(\.coordinate).map { MKMapPoint($0) })
    }
}
