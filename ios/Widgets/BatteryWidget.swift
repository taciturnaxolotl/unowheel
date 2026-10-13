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
        let snapshot = BoardSnapshot.load()
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
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Board battery")
        .description("Battery level from the last connection.")
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
                Text("No board yet").font(.caption).multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
        }
    }

    private var percentFallback: Int { entry.snapshot?.batteryPercent ?? 0 }

    private func ring(_ snapshot: BoardSnapshot, lineWidth: CGFloat) -> some View {
        let percent = snapshot.batteryPercent ?? 0
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: Double(percent) / 100)
                .stroke(batteryColor(percent), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(percent)")
                    .font(.system(.title, design: .rounded).weight(.semibold).monospacedDigit())
                Text("%").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ snapshot: BoardSnapshot) -> some View {
        Group {
            if snapshot.connected && snapshot.charging == true {
                Label("Charging", systemImage: "bolt.fill")
                    .foregroundStyle(.green)
            } else if snapshot.connected {
                Label("Connected", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.green)
            } else {
                Text(shortAge(from: snapshot.updatedAt, to: entry.date))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func small(_ snapshot: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
            }
            ring(snapshot, lineWidth: 9)
                .frame(maxWidth: .infinity)
            if let range = snapshot.range {
                Text("\(range) left").font(.caption2.weight(.semibold)).lineLimit(1)
            }
            status(snapshot)
        }
    }

    private func medium(_ snapshot: BoardSnapshot) -> some View {
        HStack(spacing: 16) {
            ring(snapshot, lineWidth: 10)
                .frame(width: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text(snapshot.title).font(.headline).lineLimit(1)
                Text(snapshot.model).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let range = snapshot.range {
                    Label("\(range) left", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption.weight(.semibold))
                }
                if let mode = snapshot.rideMode {
                    Label(mode, systemImage: "figure.skateboarding").font(.caption)
                }
                if let voltage = snapshot.voltage {
                    Label(String(format: "%.1f V", voltage), systemImage: "bolt").font(.caption)
                }
                if let lifetime = snapshot.lifetime {
                    Label(lifetime, systemImage: "road.lanes").font(.caption)
                }
                status(snapshot)
            }
            Spacer(minLength: 0)
        }
    }

    private func circular(_ snapshot: BoardSnapshot) -> some View {
        Gauge(value: Double(snapshot.batteryPercent ?? 0), in: 0...100) {
            Image(systemName: "circle.circle")
        } currentValueLabel: {
            Text("\(snapshot.batteryPercent ?? 0)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private func rectangular(_ snapshot: BoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title).font(.headline).widgetAccentable()
            Gauge(value: Double(snapshot.batteryPercent ?? 0), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(snapshot.batteryPercent ?? 0)%")
            }
            .gaugeStyle(.accessoryLinearCapacity)
            if let range = snapshot.range {
                Text("\(range) left").font(.caption)
            } else {
                status(snapshot)
            }
        }
    }

    private func inline(_ snapshot: BoardSnapshot) -> some View {
        Label(snapshot.range.map { "\(snapshot.batteryPercent ?? 0)% · \($0)" } ?? "\(snapshot.batteryPercent ?? 0)% \(snapshot.title)",
              systemImage: "circle.circle")
    }
}

#Preview(as: .systemSmall) {
    BatteryWidget()
} timeline: {
    BatteryEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemMedium) {
    BatteryWidget()
} timeline: {
    BatteryEntry(date: .now, snapshot: .preview)
}
