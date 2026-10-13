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
                    SpeedReadout(state: state, size: 40)
                        .padding(.leading, 4)
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
                    StatsRow(context: context)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: state.state.symbol)
                        .foregroundStyle(stateColor(state.state))
                    Text("\(state.speed)")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
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
            HStack(alignment: .bottom) {
                SpeedReadout(state: state, size: 52)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    BatteryPill(percent: state.batteryPercent)
                    if !state.range.isEmpty {
                        Text("\(state.range) left")
                            .font(.callout.weight(.medium).monospacedDigit())
                        if !state.rangeLearned {
                            Text("rated, still learning")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            BatteryBar(percent: state.batteryPercent)
            StatsRow(context: context)
        }
        .foregroundStyle(.white)
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
                                range: "4.1 mi", rangeLearned: true, state: .riding, topSpeed: 17)
    RideAttributes.ContentState(speed: 0, unit: "mph", batteryPercent: 18, rideMode: "Redwood", trip: "6.0 mi",
                                range: "0.9 mi", rangeLearned: false, state: .stopped, topSpeed: 17)
}
