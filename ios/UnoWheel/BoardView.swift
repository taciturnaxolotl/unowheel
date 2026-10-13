import OnewheelKit
import SwiftUI

struct BoardView: View {
    @Environment(BoardConnection.self) private var connection
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric
    @State private var showingLog = false
    @State private var renaming = false
    @State private var draftName = ""

    private var t: Telemetry { connection.telemetry }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                status
                if connection.phase == .unlocked {
                    if let faults = t.status?.faults, !faults.isEmpty { faultBanner(faults) }
                    speedAndBattery
                    controls
                    statsGrid
                    if t.reportsCellVoltages { cells }
                    if !t.battery.isEmpty { batteryCard }
                }
            }
            .padding()
        }
        .navigationTitle(connection.displayName ?? "Board")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Disconnect", role: .destructive) { connection.disconnect() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename board", systemImage: "pencil") {
                        draftName = connection.nickname ?? ""
                        renaming = true
                    }
                    Section {
                        Picker(selection: $useMetric) {
                            Label("Miles", systemImage: "road.lanes").tag(false)
                            Label("Kilometres", systemImage: "ruler").tag(true)
                        } label: {
                            Label("Units", systemImage: "ruler")
                        }
                        .pickerStyle(.menu)
                        Toggle(isOn: Binding(get: { connection.autoConnect }, set: connection.setAutoConnect)) {
                            Label("Auto-connect", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    Button("Connection log", systemImage: "text.alignleft") { showingLog = true }
                    Button("Forget unlock code", systemImage: "key.slash", role: .destructive) {
                        connection.forgetResponse()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: .constant(connection.phase == .needsResponse)) {
            UnlockView()
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingLog) {
            LogView()
        }
        .alert("Rename board", isPresented: $renaming) {
            TextField(connection.boardName ?? "Name", text: $draftName)
            Button("Save") { connection.rename(to: draftName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to use the serial number.")
        }
    }

    @ViewBuilder private var status: some View {
        switch connection.phase {
        case .connecting(let name):
            ProgressRow(text: "Connecting to \(name)")
        case .handshaking:
            ProgressRow(text: "Unlocking")
        case .needsResponse:
            Label("Locked", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        default:
            HStack {
                Text(t.model.displayName).font(.headline)
                Spacer()
                if let fw = t.firmwareRevision, let hw = t.hardwareRevision {
                    Text(verbatim: "fw \(fw) · hw \(hw)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var speedAndBattery: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(speedText)
                        .font(.system(size: 72, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text(useMetric ? "km/h" : "mph")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                BatteryRing(percent: t.batteryPercent ?? 0, tint: batteryTint)
                    .frame(width: 112, height: 112)
            }
            if t.status?.charging == true {
                Divider()
                Label("Charging", systemImage: "bolt.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let km = connection.rangeKm {
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text("\(distance(km: km, decimals: km < 16 ? 1 : 0) ?? "") left")
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                    } icon: {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .foregroundStyle(.tint)
                    }
                    Spacer()
                    Text(connection.range.isLearned ? "Learned" : "Rated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
    }

    private func faultBanner(_ faults: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Board fault", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            ForEach(faults, id: \.self) { Text($0).font(.subheadline) }
        }
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 20))
    }

    private var batteryCard: some View {
        let b = t.battery
        return VStack(alignment: .leading, spacing: 10) {
            Text("Battery").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if let health = b.healthPercent {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(health)%").font(.title2.weight(.semibold).monospacedDigit())
                    Text("health").foregroundStyle(.secondary)
                    Spacer()
                    if let cycles = b.cycles {
                        Text("\(cycles) cycle\(cycles == 1 ? "" : "s")").font(.headline.monospacedDigit())
                    }
                }
                ProgressView(value: Double(health), total: 100)
                    .tint(health > 80 ? .green : health > 60 ? .orange : .red)
            }
            Divider()
            if let cells = b.cellType { LabeledContent("Cells", value: cells) }
            if let id = b.batteryID {
                LabeledContent("Battery ID") {
                    Text(verbatim: "\(id) · \(String(id, radix: 16, uppercase: true))")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
            }
            if let boot = b.bootloaderVersion { LabeledContent("Bootloader", value: "\(boot)") }
        }
        .font(.subheadline)
        .padding(20)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !t.model.rideModes.isEmpty {
                Text("Ride mode")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(t.model.rideModes) { mode in
                        let selected = t.rideMode == mode.value
                        Button {
                            if !selected { connection.setRideMode(mode) }
                        } label: {
                            Text(mode.name)
                                .font(.subheadline.weight(selected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary),
                                            in: .rect(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .sensoryFeedback(.selection, trigger: t.rideMode)
                if let mode = t.rideMode {
                    if let current = t.model.rideModes.first(where: { $0.value == mode }) {
                        Text(current.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(.default, value: mode)
                    } else {
                        Text("Unknown mode \(mode)")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                Divider()
            } else if let mode = t.rideMode {
                LabeledContent("Ride mode", value: t.model.rideModeName(mode))
                Divider()
            }
            Toggle(isOn: Binding(get: { t.lightsOn ?? false }, set: connection.setLights)) {
                Label("Lights", systemImage: (t.lightsOn ?? false) ? "lightbulb.max.fill" : "lightbulb")
            }
        }
        .padding(20)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if let volts = t.batteryVoltage {
                Stat("Voltage", String(format: "%.1f V", volts), icon: "bolt")
            }
            if t.usesModernTelemetry {
                Stat(t.isRegenerating ? "Regen" : "Power", t.powerWatts.map { abs($0) < 10 ? "Idle" : String(format: "%.0f W", abs($0)) },
                     icon: t.isRegenerating ? "arrow.uturn.backward" : "bolt.horizontal")
            } else {
                Stat(t.isRegenerating ? "Regen" : "Current", t.currentAmps.map { String(format: "%.1f A", abs($0)) },
                     icon: t.isRegenerating ? "arrow.uturn.backward" : "arrow.forward")
            }
            Stat("Motor", temperature(t.motorTemperatureC), icon: "thermometer.medium")
            Stat("Controller", temperature(t.controllerTemperatureC), icon: "cpu")
            Stat("Battery temp", temperature(t.batteryTemperatureC), icon: "battery.100")
            Stat("Trip", distance(km: t.tripKilometres), icon: "point.topleft.down.to.point.bottomright.curvepath")
            Stat("Trip used", t.tripAmpHours.map { String(format: "%.2f Ah", $0) }, icon: "minus.circle")
            Stat("Trip regen", t.tripRegenAmpHours.map { String(format: "%.2f Ah", $0) }, icon: "plus.circle")
            Stat("Lifetime", t.lifetimeMiles.map { useMetric ? "\(Int(Double($0) * 1.60934)) km" : "\($0) mi" }, icon: "road.lanes")
            Stat("Pitch", t.pitch.map { String(format: "%.1f°", $0) }, icon: "angle")
            Stat("Efficiency", connection.range.whPerKm.map {
                useMetric ? String(format: "%.1f Wh/km", $0) : String(format: "%.1f Wh/mi", $0 * 1.60934)
            }, icon: "leaf")
        }
    }

    private var cells: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cells").font(.headline)
                Spacer()
                if !t.batteryCellsComplete {
                    Text("\(t.batteryCells.count) of \(t.model.cellCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            let values = t.batteryCells.values
            let low = values.min() ?? 0
            let high = values.max() ?? 0
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 6) {
                ForEach(0..<t.model.cellCount, id: \.self) { index in
                    let volts = t.batteryCells[index]
                    Text(volts.map { String(format: "%.2f", $0) } ?? "–")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(volts == nil ? .secondary : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(volts == low && high - low > 0.05 && t.batteryCellsComplete
                                    ? AnyShapeStyle(.orange.opacity(0.3)) : AnyShapeStyle(.fill.tertiary),
                                    in: .rect(cornerRadius: 8))
                }
            }
            if t.batteryCellsComplete {
                Text(String(format: "Spread %.2f V", high - low))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.fill.quaternary, in: .rect(cornerRadius: 20))
    }

    private var speedText: String {
        let speed = (useMetric ? t.speedKPH : t.speedMPH) ?? 0
        return String(format: "%.0f", speed)
    }

    private var batteryTint: Color {
        switch t.batteryPercent ?? 0 {
        case ..<20: .red
        case ..<40: .orange
        default: .green
        }
    }

    private func temperature(_ celsius: Int?) -> String? {
        guard let celsius else { return nil }
        return useMetric ? "\(celsius) °C" : "\(Int((Double(celsius) * 9 / 5 + 32).rounded())) °F"
    }

    private func distance(km: Double?, decimals: Int = 2) -> String? {
        guard let km else { return nil }
        let value = useMetric ? km : km * 0.621371
        return String(format: "%.\(decimals)f %@", value, useMetric ? "km" : "mi")
    }
}

private struct BatteryRing: View {
    let percent: Int
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(.fill.secondary, lineWidth: 11)
            Circle()
                .trim(from: 0, to: Double(max(0, min(percent, 100))) / 100)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: percent)
            VStack(spacing: 0) {
                Text("\(percent)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("% battery")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent")
    }
}

private struct Stat: View {
    let title: String
    let value: String?
    let icon: String

    init(_ title: String, _ value: String?, icon: String) {
        self.title = title
        self.value = value
        self.icon = icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.title3.monospacedDigit().weight(.medium))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.fill.quaternary, in: .rect(cornerRadius: 14))
    }
}

private struct ProgressRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct LogView: View {
    @Environment(BoardConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(connection.log.reversed(), id: \.self) { line in
                Text(line).font(.caption.monospaced())
            }
            .navigationTitle("Connection log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: connection.log.joined(separator: "\n"))
                }
            }
        }
    }
}
