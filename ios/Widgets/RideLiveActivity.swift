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
                        SideBattery(percent: state.batteryPercent, tint: batteryColor(state.batteryPercent))
                            .frame(height: 26)
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

/// Left of the battery: a speed gauge, always shown so the bar keeps its
/// size, or a bolt while charging.
private struct LeadingBadge: View {
    let state: RideAttributes.ContentState

    var body: some View {
        if state.state == .charging {
            Image(systemName: "bolt.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.green)
        } else {
            // Full scale is the model's top speed; the arc turns red near pushback.
            let fraction = Double(state.speed) / Double(max(state.speedMax, 1))
            ArcGauge(fraction: fraction, tint: fraction > 0.85 ? .red : .orange, lineWidth: 8) {
                VStack(spacing: -4) {
                    Text("\(state.speed)")
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(state.unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Lock screen: the battery as one big bar and the range under it. Speed
/// only appears while moving.
private struct LockScreenRide: View {
    let context: ActivityViewContext<RideAttributes>

    var body: some View {
        let state = context.state
        let charging = state.state == .charging
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(context.attributes.boardName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(alignment: .center, spacing: 16) {
                LeadingBadge(state: state)
                    .frame(width: 92, height: 92)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    SideBattery(percent: state.batteryPercent,
                                tint: charging ? .green : batteryColor(state.batteryPercent),
                                showsPercent: true)
                        .frame(width: 160, height: 50)
                    Text(mainLine(state))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func mainLine(_ state: RideAttributes.ContentState) -> String {
        if state.state == .charging {
            if state.toppingOff || state.batteryPercent >= 88 { return "Topping off" }
            if let full = state.fullAt, full > .now {
                let minutes = max(1, Int((full.timeIntervalSinceNow / 60).rounded()))
                return "~\(minutes) min to 90%"
            }
            return state.chargeWatts > 0 ? "\(state.chargeWatts) W" : "Charging"
        }
        return state.range.isEmpty ? "" : "\(state.range) left"
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
