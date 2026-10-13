import SwiftUI
import WidgetKit

struct BatteryEntry: TimelineEntry {
    let date: Date
    let snapshot: BoardSnapshot?
}

struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(BatteryEntry(date: .now, snapshot: context.isPreview ? .preview : BoardSnapshot.load() ?? .preview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        var snapshot = BoardSnapshot.load()
        // Charging is only true while the app can see the board. If the
        // estimate has passed, call it full rather than show a stale ETA.
        if let full = snapshot?.fullAt, full < .now { snapshot?.fullAt = nil }
        // One entry per minute for the first hour, then hourly, so the coarse
        // "5m" / "2h" label stays right without the app having to wake.
        let now = Date.now
        var dates = (0..<60).map { now.addingTimeInterval(Double($0) * 60) }
        dates += (1...12).map { now.addingTimeInterval(Double($0) * 3600) }
        let entries = dates.map { BatteryEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// "now", "5m", "2h", "3d": how long ago, without the ticking seconds.
func shortAge(from date: Date, to now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m ago"
    case ..<86400: return "\(Int(seconds / 3600))h ago"
    default: return "\(Int(seconds / 86400))d ago"
    }
}

struct BatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BoardBattery", provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Board battery")
        .description("Battery, range and your last ride.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

func batteryColor(_ percent: Int) -> Color {
    switch percent {
    case ..<20: .red
    case ..<40: .orange
    default: .green
    }
}

/// A 270 degree arc gauge, open at the bottom like a fuel gauge.
struct ArcGauge<Center: View>: View {
    let fraction: Double
    let tint: Color
    var lineWidth: CGFloat = 12
    @ViewBuilder let center: Center

    private let sweep = 0.75

    var body: some View {
        ZStack {
            arc(to: 1).stroke(.white.opacity(0.1), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            arc(to: max(0.001, min(fraction, 1)))
                .stroke(AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                        startAngle: .degrees(135), endAngle: .degrees(135 + 360 * sweep * max(fraction, 0.01))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: tint.opacity(0.45), radius: lineWidth / 2)
            center
        }
        .padding(lineWidth / 2)
    }

    private func arc(to fraction: Double) -> some Shape {
        Circle().trim(from: 0, to: sweep * fraction).rotation(.degrees(135))
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BatteryEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryCircular: circular(snapshot)
            case .accessoryRectangular: rectangular(snapshot)
            case .accessoryInline: inline(snapshot)
            case .systemMedium: medium(snapshot)
            default: small(snapshot)
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "circle.circle").font(.title)
                Text("No board yet").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }

    private func isCharging(_ s: BoardSnapshot) -> Bool { s.connected && s.charging == true }

    private func tint(_ s: BoardSnapshot) -> Color {
        isCharging(s) ? .green : batteryColor(s.batteryPercent ?? 0)
    }

    private func gauge(_ s: BoardSnapshot, lineWidth: CGFloat, digits: Font) -> some View {
        let percent = s.batteryPercent ?? 0
        return ArcGauge(fraction: Double(percent) / 100, tint: tint(s), lineWidth: lineWidth) {
            VStack(spacing: -2) {
                Text("\(percent)")
                    .font(digits.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.6)
                Image(systemName: isCharging(s) ? "bolt.fill" : "battery.75percent")
                    .font(.caption2)
                    .foregroundStyle(isCharging(s) ? .green : .secondary)
            }
        }
    }

    private func status(_ s: BoardSnapshot) -> some View {
        Text(isCharging(s) ? "Charging" : s.connected ? "Connected" : shortAge(from: s.updatedAt, to: entry.date))
            .font(.caption2)
            .foregroundStyle(s.connected ? .green : .secondary)
            .lineLimit(1)
    }

    private func headline(_ s: BoardSnapshot) -> String? {
        if isCharging(s) {
            if s.toppingOff == true { return "Topping off" }
            if let full = s.fullAt { return "90% at \(full.formatted(date: .omitted, time: .shortened))" }
            return s.chargeWatts.map { "\($0) W" }
        }
        return s.range.map { "\($0) left" }
    }

    private func small(_ s: BoardSnapshot) -> some View {
        Group {
            if isCharging(s) { chargingSmall(s) } else { restingSmall(s) }
        }
    }

    private func restingSmall(_ s: BoardSnapshot) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(s.title).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                status(s)
            }
            gauge(s, lineWidth: 11, digits: .system(size: 34, design: .rounded))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let range = s.range {
                Label("\(range) left", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
        }
    }

    /// Charging uses a battery shape, not the arc, so it can't be mistaken
    /// for a speedometer.
    private func chargingSmall(_ s: BoardSnapshot) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").foregroundStyle(.green)
                Text("\(s.batteryPercent ?? 0)%").monospacedDigit()
            }
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            SegmentedBattery(percent: s.batteryPercent ?? 0)
                .frame(height: 44)
            Text(chargeLine(s))
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// "~25 min", "Topping off", or the charge power while we wait to estimate.
    private func chargeLine(_ s: BoardSnapshot) -> String {
        if s.toppingOff == true { return "Topping off" }
        if let full = s.fullAt {
            let minutes = max(1, Int((full.timeIntervalSince(entry.date) / 60).rounded()))
            return minutes < 60 ? "~\(minutes) min to 90%" : "~\(minutes / 60)h \(minutes % 60)m to 90%"
        }
        return s.chargeWatts.map { "\($0) W" } ?? "Charging"
    }

    private func medium(_ s: BoardSnapshot) -> some View {
        Group {
            if isCharging(s) { chargingMedium(s) } else { restingMedium(s) }
        }
    }

    private func chargingMedium(_ s: BoardSnapshot) -> some View {
        HStack(spacing: 18) {
            VStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                    Text("\(s.batteryPercent ?? 0)%").monospacedDigit()
                }
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                SegmentedBattery(percent: s.batteryPercent ?? 0)
                    .frame(width: 140, height: 50)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.headline).lineLimit(1)
                StatRow(icon: "clock.fill", tint: .green, text: chargeLine(s))
                if let watts = s.chargeWatts {
                    StatRow(icon: "powerplug.fill", tint: .yellow, text: "\(watts) W")
                }
                if let range = s.range {
                    StatRow(icon: "point.topleft.down.to.point.bottomright.curvepath", tint: .blue, text: "\(range) range")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func restingMedium(_ s: BoardSnapshot) -> some View {
        HStack(spacing: 16) {
            gauge(s, lineWidth: 13, digits: .system(size: 40, design: .rounded))
                .frame(width: 124)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.title).font(.headline).lineLimit(1)
                    Spacer()
                    status(s)
                }
                if let range = s.range {
                    StatRow(icon: "point.topleft.down.to.point.bottomright.curvepath", tint: .blue, text: "\(range) left")
                }
                if let ride = s.lastRide {
                    StatRow(icon: "gauge.with.needle.fill", tint: .orange, text: "\(ride.topSpeed) \(ride.unit) top")
                    if !ride.trip.isEmpty {
                        StatRow(icon: "flag.checkered", tint: .purple, text: "\(ride.trip) in \(ride.minutes)m")
                    }
                } else {
                    if let mode = s.rideMode {
                        StatRow(icon: "figure.skateboarding", tint: .orange, text: mode)
                    }
                    if let lifetime = s.lifetime {
                        StatRow(icon: "road.lanes", tint: .purple, text: "\(lifetime) total")
                    }
                }
            }
        }
    }

    private func circular(_ s: BoardSnapshot) -> some View {
        Gauge(value: Double(s.batteryPercent ?? 0), in: 0...100) {
            Image(systemName: isCharging(s) ? "bolt.fill" : "circle.circle")
        } currentValueLabel: {
            Text("\(s.batteryPercent ?? 0)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }

    private func rectangular(_ s: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(s.title).font(.headline).widgetAccentable()
                Spacer()
                Text("\(s.batteryPercent ?? 0)%").font(.headline.monospacedDigit())
            }
            Gauge(value: Double(s.batteryPercent ?? 0), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
            Text(headline(s) ?? shortAge(from: s.updatedAt, to: entry.date)).font(.caption)
        }
    }

    private func inline(_ s: BoardSnapshot) -> some View {
        Label("\(s.batteryPercent ?? 0)%" + (headline(s).map { " · \($0)" } ?? ""),
              systemImage: isCharging(s) ? "bolt.fill" : "circle.circle")
    }
}

/// Five cells, filled left to right. The partly filled cell fills from the
/// bottom, like a battery icon.
struct SegmentedBattery: View {
    let percent: Int
    var segments = 5

    var body: some View {
        let perCell = 100.0 / Double(segments)
        HStack(spacing: 5) {
            ForEach(0..<segments, id: \.self) { index in
                let fill = min(1, max(0, (Double(percent) - Double(index) * perCell) / perCell))
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08))
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.green.gradient)
                            .frame(height: proxy.size.height * fill)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
        }
        .padding(5)
        .background(Color.green.opacity(0.18), in: .rect(cornerRadius: 10))
    }
}

/// A coloured icon and a value, one per line.
struct StatRow: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

#Preview(as: .systemSmall) {
    BatteryWidget()
} timeline: {
    BatteryEntry(date: .now, snapshot: .preview)
    BatteryEntry(date: .now, snapshot: .chargingPreview)
}

#Preview(as: .systemMedium) {
    BatteryWidget()
} timeline: {
    BatteryEntry(date: .now, snapshot: .preview)
    BatteryEntry(date: .now, snapshot: .chargingPreview)
}
