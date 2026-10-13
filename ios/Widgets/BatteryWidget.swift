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

    /// "now", "5m ago": when the app last heard from the board.
    private func age(_ s: BoardSnapshot) -> some View {
        Text(s.connected ? "now" : shortAge(from: s.updatedAt, to: entry.date))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }

    private func headline(_ s: BoardSnapshot) -> String? {
        if isCharging(s) {
            if s.toppingOff == true || (s.batteryPercent ?? 0) >= 88 { return "Topping off" }
            if let full = s.fullAt, full > entry.date { return "90% at \(full.formatted(date: .omitted, time: .shortened))" }
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
            Text(s.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Text("\(s.batteryPercent ?? 0)%")
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            SideBattery(percent: s.batteryPercent ?? 0, tint: tint(s))
                .frame(height: 44)
            Spacer(minLength: 0)
            HStack {
                if let range = s.range {
                    Label("\(range) left", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                age(s)
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
            SideBattery(percent: s.batteryPercent ?? 0)
                .frame(height: 44)
            HStack(alignment: .firstTextBaseline) {
                Text(chargeLine(s))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                age(s)
            }
        }
    }

    /// "~25 min", "Topping off", or the charge power while we wait to estimate.
    private func chargeLine(_ s: BoardSnapshot) -> String {
        if s.toppingOff == true || (s.batteryPercent ?? 0) >= 88 { return "Topping off" }
        if let full = s.fullAt, full > entry.date {
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
                SideBattery(percent: s.batteryPercent ?? 0)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) { age(s) }
        }
    }

    private func restingMedium(_ s: BoardSnapshot) -> some View {
        HStack(spacing: 16) {
            VStack(spacing: 10) {
                Text("\(s.batteryPercent ?? 0)%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                SideBattery(percent: s.batteryPercent ?? 0, tint: tint(s))
                    .frame(width: 140, height: 50)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.headline).lineLimit(1)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) { age(s) }
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

/// One battery lying on its side, filled left to right, with a terminal nub.
struct SideBattery: View {
    let percent: Int
    var tint: Color = .green

    var body: some View {
        let fraction = Double(max(0, min(percent, 100))) / 100
        HStack(spacing: 3) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tint.gradient)
                        .frame(width: max(14, (proxy.size.width - 10) * fraction))
                        .padding(5)
                        .shadow(color: tint.opacity(0.4), radius: 6)
                }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.45), lineWidth: 2))
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(tint.opacity(0.45))
                .frame(width: 5)
                .padding(.vertical, 12)
        }
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
