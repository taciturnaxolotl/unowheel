import ActivityKit
import SwiftUI
import WidgetKit

struct RideLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideAttributes.self) { context in
            LockScreenRide(context: context)
                .padding(16)
                .activityBackgroundTint(.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if state.state == .charging {
                        Label("\(state.chargeWatts) W", systemImage: "bolt.fill")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.green)
                            .padding(.leading, 4)
                    } else {
                        SpeedReadout(state: state, size: 40)
                            .padding(.leading, 4)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 4) {
                        BatteryPill(percent: state.batteryPercent)
                        if !state.range.isEmpty {
                            Text("\(state.range) left")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    StateBadge(state: state.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if state.state == .charging {
                        if let full = state.fullAt, full > .now {
                            Text("90% in \(Text(timerInterval: Date.now...full, countsDown: true))")
                                .font(.callout.monospacedDigit())
                        }
                    } else {
                        StatsRow(context: context)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: state.state.symbol)
                        .foregroundStyle(stateColor(state.state))
                    if state.state != .charging {
                        Text("\(state.speed)")
                            .font(.body.weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText())
                    }
                }
            } compactTrailing: {
                Text("\(state.batteryPercent)%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(batteryColor(state.batteryPercent))
            } minimal: {
                Gauge(value: Double(state.batteryPercent), in: 0...100) {
                    EmptyView()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(batteryColor(state.batteryPercent))
            }
        }
    }
}

func stateColor(_ state: RideState) -> Color {
    switch state {
    case .riding: .orange
    case .braking: .green
    case .stopped: .secondary
    case .charging: .green
    }
}

private struct LockScreenRide: View {
    let context: ActivityViewContext<RideAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(context.attributes.boardName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StateBadge(state: state.state)
            }
            if state.state == .charging {
                ChargingBody(state: state)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    Speedometer(state: state)
                        .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 6) {
                        BatteryPill(percent: state.batteryPercent)
                        BatteryBar(percent: state.batteryPercent)
                        if !state.range.isEmpty {
                            Text("\(state.range) left\(state.rangeLearned ? "" : " (rated)")")
                                .font(.callout.weight(.medium).monospacedDigit())
                        }
                    }
                }
                StatsRow(context: context)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Speed on an arc, scaled to the board's usual top speed.
private struct Speedometer: View {
    let state: RideAttributes.ContentState

    var body: some View {
        let fraction = Double(state.speed) / Double(max(state.speedMax, 1))
        ArcGauge(fraction: fraction, tint: fraction > 0.85 ? .red : .orange, lineWidth: 9) {
            VStack(spacing: -4) {
                Text("\(state.speed)")
                    .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(state.unit).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChargingBody: View {
    let state: RideAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ArcGauge(fraction: Double(state.batteryPercent) / 100, tint: .green, lineWidth: 9) {
                VStack(spacing: -2) {
                    Text("\(state.batteryPercent)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green)
                }
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                if state.toppingOff {
                    Text("Topping off").font(.title2.weight(.semibold))
                } else if let full = state.fullAt, full > .now {
                    Text(timerInterval: Date.now...full, countsDown: true)
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("to 90%, about \(full.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Charging").font(.title2.weight(.semibold))
                }
                if state.chargeWatts > 0 {
                    Label("\(state.chargeWatts) W", systemImage: "bolt.horizontal")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SpeedReadout: View {
    let state: RideAttributes.ContentState
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(state.speed)")
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(state.unit)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StateBadge: View {
    let state: RideState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(stateColor(state).opacity(0.25), in: .capsule)
            .foregroundStyle(stateColor(state))
    }
}

private struct StatsRow: View {
    let context: ActivityViewContext<RideAttributes>

    var body: some View {
        let state = context.state
        HStack {
            Label {
                Text(timerInterval: context.attributes.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
            } icon: {
                Image(systemName: "timer")
            }
            Spacer()
            if !state.trip.isEmpty {
                Label(state.trip, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                Spacer()
            }
            Label("\(state.topSpeed) top", systemImage: "gauge.with.needle")
            if !state.rideMode.isEmpty {
                Spacer()
                Text(state.rideMode)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct BatteryBar: View {
    let percent: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(batteryColor(percent).gradient)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(percent, 100))) / 100)
            }
        }
        .frame(height: 6)
    }
}

private struct BatteryPill: View {
    let percent: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: percent < 20 ? "battery.25" : percent < 60 ? "battery.50" : "battery.100")
            Text("\(percent)%").monospacedDigit()
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(batteryColor(percent))
    }
}

#Preview("Lock screen", as: .content, using: RideAttributes(boardName: "Pinty", startedAt: .now.addingTimeInterval(-754))) {
    RideLiveActivity()
} contentStates: {
    RideAttributes.ContentState(speed: 14, unit: "mph", batteryPercent: 72, rideMode: "Pacific", trip: "3.2 mi",
                                range: "4.1 mi", rangeLearned: true, state: .riding, topSpeed: 17, speedMax: 20)
    RideAttributes.ContentState(speed: 0, unit: "mph", batteryPercent: 18, rideMode: "Redwood", trip: "6.0 mi",
                                range: "0.9 mi", rangeLearned: false, state: .stopped, topSpeed: 17, speedMax: 20)
    RideAttributes.ContentState(speed: 0, unit: "mph", batteryPercent: 46, rideMode: "Pacific", trip: "",
                                range: "", rangeLearned: false, state: .charging, topSpeed: 0, speedMax: 20,
                                chargeWatts: 170, fullAt: .now.addingTimeInterval(1860))
}
