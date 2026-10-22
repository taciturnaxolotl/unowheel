import Charts
import MapKit
import OnewheelKit
import SwiftUI

struct RidesView: View {
    @Environment(BoardConnection.self) private var connection
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric

    private var rides: [Ride] { connection.rides.rides(for: connection.boardName) }

    var body: some View {
        List {
            if connection.isRecording {
                Label("Recording", systemImage: "record.circle")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            }
            if rides.isEmpty, !connection.isRecording {
                ContentUnavailableView("No rides yet", systemImage: "map",
                                       description: Text("Rides record on their own once the board moves."))
            }
            ForEach(rides) { ride in
                NavigationLink(value: ride.id) {
                    RideRow(ride: ride, useMetric: useMetric)
                }
            }
            .onDelete { offsets in
                for index in offsets { connection.rides.delete(rides[index]) }
            }
        }
        .navigationTitle("Rides")
        #if DEBUG
        .navigationDestination(isPresented: .constant(CommandLine.arguments.contains("-open-ride") && !rides.isEmpty)) {
            if let first = rides.first { RideDetailView(ride: first) }
        }
        #endif
        .navigationDestination(for: UUID.self) { id in
            if let ride = connection.rides.rides.first(where: { $0.id == id }) {
                RideDetailView(ride: ride)
            }
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
                Text(ride.startedAt.formatted(.dateTime.weekday(.wide).hour().minute()))
                    .font(.headline)
                Text("\(formatDistance(ride.distanceKm, metric: useMetric)) · \(formatDuration(ride.duration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatSpeed(ride.topSpeedKPH, metric: useMetric))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }
}

/// The route drawn as a line, scaled to fit, without a map underneath.
private struct RouteThumbnail: View {
    let ride: Ride

    var body: some View {
        Canvas { context, size in
            let located = ride.points.compactMap { p -> CGPoint? in
                guard let lat = p.latitude, let lon = p.longitude else { return nil }
                return CGPoint(x: lon, y: lat)
            }
            guard located.count > 1,
                  let minX = located.map(\.x).min(), let maxX = located.map(\.x).max(),
                  let minY = located.map(\.y).min(), let maxY = located.map(\.y).max() else { return }
            let span = max(maxX - minX, maxY - minY, 0.0001)
            let inset: CGFloat = 8
            let scale = (min(size.width, size.height) - inset * 2) / span
            var path = Path()
            for (i, p) in located.enumerated() {
                let point = CGPoint(x: inset + (p.x - minX) * scale + (size.width - inset * 2 - (maxX - minX) * scale) / 2,
                                    y: size.height - inset - (p.y - minY) * scale - (size.height - inset * 2 - (maxY - minY) * scale) / 2)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
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

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if ride.hasRoute {
                    RideMap(ride: ride)
                        .frame(height: 320)
                        .clipShape(.rect(cornerRadius: 24))
                }
                stats
                if ride.points.count > 2 { speedChart }
            }
            .padding()
        }
        .navigationTitle(ride.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            RideStat(title: "Distance", value: formatDistance(ride.distanceKm, metric: useMetric), icon: "point.topleft.down.to.point.bottomright.curvepath", tint: .blue)
            RideStat(title: "Time", value: formatDuration(ride.duration), icon: "timer", tint: .purple)
            RideStat(title: "Top speed", value: formatSpeed(ride.topSpeedKPH, metric: useMetric), icon: "gauge.with.needle.fill", tint: .orange)
            RideStat(title: "Average", value: formatSpeed(ride.averageMovingKPH, metric: useMetric), icon: "speedometer", tint: .yellow)
            if let used = ride.batteryUsed {
                RideStat(title: "Battery used", value: "\(used)%", icon: "battery.50percent", tint: .green)
            }
            RideStat(title: "Moving", value: formatDuration(ride.movingTime), icon: "figure.skateboarding", tint: .teal)
        }
    }

    private var speedChart: some View {
        let factor = useMetric ? 1 : 0.621371
        return VStack(alignment: .leading, spacing: 8) {
            Text("Speed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Chart(ride.points, id: \.time) { point in
                AreaMark(x: .value("Time", point.time), y: .value("Speed", point.speedKPH * factor))
                    .foregroundStyle(.linearGradient(colors: [.orange.opacity(0.35), .orange.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.time), y: .value("Speed", point.speedKPH * factor))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 140)
        }
        .padding(16)
        .background(.fill.tertiary, in: .rect(cornerRadius: 20))
    }
}

/// The route on a map, coloured from green (slow) to red (near top speed).
private struct RideMap: View {
    let ride: Ride

    private static let colors: [Color] = [.green, .mint, .yellow, .orange, .red]

    var body: some View {
        let segments = ride.speedSegments(bands: Self.colors.count)
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                MapPolyline(coordinates: segment.points.compactMap(\.coordinate))
                    .stroke(Self.colors[segment.band], style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = ride.points.first(where: \.hasLocation)?.coordinate {
                Annotation("Start", coordinate: start) {
                    Circle().fill(.green).stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
            if let end = ride.points.last(where: \.hasLocation)?.coordinate {
                Annotation("End", coordinate: end) {
                    Circle().fill(.red).stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
    }
}

private struct RideStat: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabel(tint: tint))
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.tertiary, in: .rect(cornerRadius: 16))
    }
}

private struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
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

func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
}
