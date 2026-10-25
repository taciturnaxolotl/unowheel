import Charts
import MapKit
import OnewheelKit
import SwiftUI

struct RidesView: View {
    @Environment(BoardConnection.self) private var connection
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric

    @State private var confirmingDiscard = false
    /// Set from the `-openRide <id prefix>` launch argument in debug builds, for screenshots.
    @State private var openedRide: UUID?

    private var rides: [Ride] { connection.rides.rides(for: connection.boardName) }

    var body: some View {
        List {
            if connection.isRecording {
                Section {
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                    Button("End ride", systemImage: "stop.circle") { connection.endRide(save: true) }
                    Button("Discard ride", systemImage: "trash", role: .destructive) { confirmingDiscard = true }
                }
            }
            if rides.contains(where: \.hasRoute) {
                Section {
                    NavigationLink {
                        HeatmapView(rides: rides)
                    } label: {
                        HeatmapMap(rides: rides, interactive: false)
                            .frame(height: 150)
                            .clipShape(.rect(cornerRadius: 14))
                            .overlay(alignment: .bottomLeading) {
                                HStack(spacing: 4) {
                                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                                    Text("Heatmap").foregroundStyle(.white)
                                }
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: .capsule)
                                    .padding(8)
                            }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            }
            if rides.isEmpty, !connection.isRecording {
                ContentUnavailableView("No rides yet", systemImage: "map",
                                       description: Text("Rides record on their own once the board moves."))
            }
            ForEach(rides) { ride in
                NavigationLink {
                    RideDetailView(ride: ride)
                } label: {
                    RideRow(ride: ride, useMetric: useMetric)
                }
            }
            .onDelete { offsets in
                for index in offsets { connection.rides.delete(rides[index]) }
            }
        }
        .navigationTitle("Rides")
        #if DEBUG
        .navigationDestination(item: $openedRide) { id in
            if let ride = rides.first(where: { $0.id == id }) { RideDetailView(ride: ride) }
        }
        .onAppear {
            // Launch arguments of the form `-key value` land in UserDefaults.
            guard let prefix = UserDefaults.standard.string(forKey: "openRide") else { return }
            openedRide = rides.first { $0.id.uuidString.hasPrefix(prefix) }?.id
        }
        #endif
        .confirmationDialog("Discard this ride?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { connection.endRide(save: false) }
        }
    }
}

private struct RideRow: View {
    let ride: Ride
    let useMetric: Bool

    var body: some View {
        HStack(spacing: 12) {
            RouteThumbnail(ride: ride)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(ride.title())
                    .font(.headline)
                    .lineLimit(1)
                Text("\(ride.startedAt.formatted(.relative(presentation: .named))) · \(formatDistance(ride.distanceKm, metric: useMetric)) · \(formatDuration(ride.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatSpeed(ride.topSpeedKPH, metric: useMetric))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }
}

/// The route as a bare line, scaled to fit, in the map's projection so
/// it matches the ride's map.
private struct RouteThumbnail: View {
    let ride: Ride
    private let inset: CGFloat = 8
    private let minSpanMetres = 5.0

    var body: some View {
        Canvas { context, size in
            guard let track = HeatRaster.Track(ride: ride) else { return }
            let rect = track.rect
            let minSpan = minSpanMetres * MKMapPointsPerMeterAtLatitude(track.points[0].coordinate.latitude)
            let scale = (min(size.width, size.height) - inset * 2) / max(rect.width, rect.height, minSpan)
            let offsetX = (size.width - rect.width * scale) / 2
            let offsetY = (size.height - rect.height * scale) / 2
            var path = Path()
            path.addLines(track.points.map { CGPoint(x: offsetX + ($0.x - rect.minX) * scale, y: offsetY + ($0.y - rect.minY) * scale) })
            context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .background(.fill.tertiary)
        .overlay {
            if !ride.hasRoute {
                Image(systemName: "figure.skateboarding").foregroundStyle(.secondary)
            }
        }
    }
}

struct RideDetailView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric
    let ride: Ride
    @State private var renaming = false
    @State private var draftTitle = ""

    /// The saved copy, so a rename or a place lookup shows up straight away.
    private var current: Ride { connection.rides.rides.first { $0.id == ride.id } ?? ride }

    var body: some View {
        ScrollView {
            Text(current.startedAt.formatted(date: .complete, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            VStack(spacing: 16) {
                if ride.hasRoute {
                    RideMap(ride: ride)
                        .frame(height: 320)
                        .clipShape(.rect(cornerRadius: 24))
                } else {
                    Label("No map. The phone recorded no location for this ride; check location access.", systemImage: "location.slash")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
                }
                stats
                if ride.points.count > 2 { RideCharts(ride: ride) }
            }
            .padding()
        }
        .navigationTitle(current.title())
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename ride", isPresented: $renaming) {
            TextField(current.title(), text: $draftTitle)
            Button("Save") { connection.rides.rename(current, to: draftTitle) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave blank to name it automatically.")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename", systemImage: "pencil") {
                    draftTitle = current.customTitle ?? ""
                    renaming = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    connection.rides.delete(ride)
                    dismiss()
                }
            }
        }
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            RideStat(title: "Distance", value: formatDistance(ride.distanceKm, metric: useMetric))
            RideStat(title: "Time", value: formatDuration(ride.duration))
            RideStat(title: "Top speed", value: formatSpeed(ride.topSpeedKPH, metric: useMetric))
            RideStat(title: "Average", value: formatSpeed(ride.averageMovingKPH, metric: useMetric))
            if let used = ride.batteryUsed {
                RideStat(title: "Battery used", value: "\(used)%")
            }
            RideStat(title: "Moving", value: formatDuration(ride.movingTime))
            if ride.hasPower {
                RideStat(title: "Energy", value: String(format: "%.0f Wh", ride.energyWh))
                RideStat(title: "Regen", value: String(format: "%.1f Wh", ride.regenWh))
                if let rate = ride.whPerKm {
                    RideStat(title: "Efficiency", value: useMetric ? String(format: "%.1f Wh/km", rate) : String(format: "%.1f Wh/mi", rate * 1.609344))
                }
                if let peak = ride.peakWatts {
                    RideStat(title: "Peak power", value: String(format: "%.0f W", peak))
                }
            }
            if let pushback = ride.pushbackKPH {
                RideStat(title: "Pushback from", value: formatSpeed(pushback, metric: useMetric))
            }
            if let weather = ride.weather {
                RideStat(title: "Weather", value: formatWeather(weather, metric: useMetric))
            }
            if let gain = ride.elevationGainM {
                RideStat(title: "Climbed", value: useMetric ? String(format: "%.0f m", gain) : String(format: "%.0f ft", gain * 3.28084))
            }
            if let motor = ride.maxMotorTempC {
                RideStat(title: "Hottest motor", value: useMetric ? "\(motor) °C" : "\(Int((Double(motor) * 9 / 5 + 32).rounded())) °F")
            }
        }
    }
}

enum RideChartKind: String, CaseIterable, Identifiable {
    case speed = "Speed", power = "Power", battery = "Battery", temperature = "Heat", pitch = "Nose"
    var id: String { rawValue }
}

/// One chart at a time, picked from what this ride actually recorded.
private struct RideCharts: View {
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric
    let ride: Ride
    @State private var kind: RideChartKind = .speed

    private var available: [RideChartKind] {
        RideChartKind.allCases.filter { kind in
            switch kind {
            case .speed: true
            case .power: ride.hasPower
            case .battery: ride.points.contains { $0.batteryPercent != nil }
            case .temperature: ride.maxMotorTempC != nil
            case .pitch: ride.peakNoseUp != nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if available.count > 1 {
                Picker("Chart", selection: $kind) {
                    ForEach(available) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            chart.frame(height: 160)
        }
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))
    }

    @ViewBuilder private var chart: some View {
        let points = ride.points
        switch kind {
        case .speed:
            let factor = useMetric ? 1 : 0.621371
            line(points.map { ($0.time, $0.speedKPH * factor) }, color: .orange, unit: useMetric ? "km/h" : "mph")
        case .power:
            // Above zero is drawing power, below is regen.
            Chart(points.filter { $0.watts != nil }, id: \.time) { point in
                BarMark(x: .value("Time", point.time), y: .value("Watts", point.watts ?? 0), width: .fixed(1.5))
                    .foregroundStyle((point.watts ?? 0) < 0 ? Color.green : Color.orange)
            }
            .chartYAxisLabel("W")
            .chartXAxis { timeAxis }
        case .battery:
            line(points.compactMap { p in p.batteryPercent.map { (p.time, Double($0)) } }, color: .green, unit: "%")
        case .pitch:
            line(points.compactMap { p in p.noseUp.map { (p.time, $0) } }, color: .purple, unit: "°")
        case .temperature:
            let convert: (Int) -> Double = { useMetric ? Double($0) : Double($0) * 9 / 5 + 32 }
            Chart {
                ForEach(points.filter { $0.motorTempC != nil }, id: \.time) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Temp", convert(p.motorTempC ?? 0)), series: .value("Part", "Motor"))
                        .foregroundStyle(by: .value("Part", "Motor"))
                }
                ForEach(points.filter { $0.controllerTempC != nil }, id: \.time) { p in
                    LineMark(x: .value("Time", p.time), y: .value("Temp", convert(p.controllerTempC ?? 0)), series: .value("Part", "Controller"))
                        .foregroundStyle(by: .value("Part", "Controller"))
                }
            }
            .chartForegroundStyleScale(["Motor": Color.red, "Controller": Color.purple])
            .chartYAxisLabel(useMetric ? "°C" : "°F")
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { timeAxis }
        }
    }

    private func line(_ values: [(Date, Double)], color: Color, unit: String) -> some View {
        Chart(values, id: \.0) { value in
            AreaMark(x: .value("Time", value.0), y: .value(unit, value.1))
                .foregroundStyle(.linearGradient(colors: [color.opacity(0.3), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", value.0), y: .value(unit, value.1))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartYAxisLabel(unit)
        .chartYScale(domain: .automatic(includesZero: kind == .speed))
        .chartXAxis { timeAxis }
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour().minute())
        }
    }
}

/// Speed colours for the ride map, slow to fast.
let speedColors: [Color] = [
    Color(red: 0.20, green: 0.78, blue: 0.45),
    Color(red: 0.62, green: 0.85, blue: 0.25),
    Color(red: 0.98, green: 0.80, blue: 0.20),
    Color(red: 0.98, green: 0.52, blue: 0.16),
    Color(red: 0.93, green: 0.23, blue: 0.23),
]

/// The route on a map: a dark outline under a smoothed line coloured from
/// green (slow) to red (near top speed).
private struct RideMap: View {
    let ride: Ride

    var body: some View {
        let smooth = ride.smoothed()
        let segments = smooth.speedSegments(bands: speedColors.count)
        let all = smooth.points.compactMap(\.coordinate)
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: all)
                .stroke(.black.opacity(0.55), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.points.compactMap(\.coordinate))
                    .stroke(speedColors[segment.band], style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = all.first {
                Annotation("Start", coordinate: start) {
                    Circle().fill(.white).stroke(.black.opacity(0.6), lineWidth: 3).frame(width: 14, height: 14)
                }
            }
            if let end = all.last {
                Annotation("End", coordinate: end) {
                    Image(systemName: "flag.checkered")
                        .font(.caption.weight(.bold))
                        .padding(5)
                        .background(.black.opacity(0.75), in: .circle)
                        .foregroundStyle(.white)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
        .overlay(alignment: .bottomTrailing) { SpeedLegend().padding(10) }
        .overlay(alignment: .topLeading) {
            if let warning = ride.routeQuality.warning {
                Label(warning, systemImage: "location.slash")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(10)
            }
        }
    }
}

extension RouteQuality {
    var warning: String? {
        switch self {
        case .good: nil
        case .droppedOut: "GPS dropped out"
        case .lowSignal: "Low GPS signal"
        }
    }
}

private struct SpeedLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("slow")
            LinearGradient(colors: speedColors, startPoint: .leading, endPoint: .trailing)
                .frame(width: 60, height: 6)
                .clipShape(.capsule)
            Text("fast")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: .capsule)
    }
}

/// Every ride on one map. The more rides along a path, the hotter it glows.
struct HeatmapMap: View {
    let rides: [Ride]
    var interactive = true

    @State private var overlay: HeatmapOverlay?

    var body: some View {
        HeatmapMapView(overlay: overlay, interactive: interactive)
            .allowsHitTesting(interactive)
            .task(id: rides.map(\.id)) {
                let rides = rides
                overlay = await Task.detached(priority: .userInitiated) { HeatmapOverlay(rides: rides) }.value
            }
    }
}

struct HeatmapView: View {
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric
    let rides: [Ride]

    var body: some View {
        HeatmapMap(rides: rides)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    FrequencyLegend()
                    HStack(spacing: 16) {
                        Label("\(rides.count) rides", systemImage: "figure.skateboarding")
                        Label(formatDistance(rides.reduce(0) { $0 + $1.distanceKm }, metric: useMetric),
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
                }
                .padding(.bottom, 24)
            }
            .navigationTitle("Heatmap")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FrequencyLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("1 ride")
            LinearGradient(stops: HeatRaster.ramp.dropFirst().map {
                Gradient.Stop(color: Color(red: $0.red, green: $0.green, blue: $0.blue), location: $0.t)
            }, startPoint: .leading, endPoint: .trailing)
                .frame(width: 60, height: 6)
                .clipShape(.capsule)
            Text("most")
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: .capsule)
    }
}

private struct RideStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    }
}

extension RidePoint {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

func formatDistance(_ km: Double, metric: Bool) -> String {
    let value = metric ? km : km * 0.621371
    return String(format: value < 10 ? "%.2f %@" : "%.1f %@", value, metric ? "km" : "mi")
}

func formatSpeed(_ kph: Double, metric: Bool) -> String {
    String(format: "%.0f %@", metric ? kph : kph * 0.621371, metric ? "km/h" : "mph")
}

func formatWeather(_ weather: Weather, metric: Bool) -> String {
    let temperature = metric ? String(format: "%.0f°C", weather.temperatureC) : String(format: "%.0f°F", weather.temperatureC * 9 / 5 + 32)
    let wind = metric ? String(format: "%.0f km/h", weather.windKPH) : String(format: "%.0f mph", weather.windKPH * 0.621371)
    return weather.precipitationMM > 0.1 ? "\(temperature), wet" : "\(temperature), wind \(wind)"
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
}
