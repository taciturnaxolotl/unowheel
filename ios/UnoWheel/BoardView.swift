import OnewheelKit
import Charts
import SwiftUI

struct BoardView: View {
    @Environment(BoardConnection.self) private var connection
    @AppStorage("useMetric") private var useMetric = Locale.current.measurementSystem == .metric
    @State private var showingLog = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var addingBoard = false
    @State private var showingRides = CommandLine.arguments.contains("-open-rides")

    private var t: Telemetry { connection.shown }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                status
                if connection.hasData {
                    if connection.isLive, let error = t.status?.error { errorBanner(error) }
                    if connection.isLive, let faults = t.status?.faults, !faults.isEmpty { faultBanner(faults) }
                    if connection.isLive, t.isCharging { chargingCard } else { speedAndBattery }
                    controls
                        .disabled(!connection.isLive)
                        .opacity(connection.isLive ? 1 : 0.5)
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
            ToolbarItem(placement: .principal) { boardPicker }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingRides = true
                } label: {
                    Image(systemName: connection.isRecording ? "record.circle" : "map")
                        .foregroundStyle(connection.isRecording ? .red : .primary)
                        .symbolEffect(.pulse, options: .repeating, isActive: connection.isRecording)
                }
                .accessibilityLabel("Rides")
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
                    }
                    Button("Connection log", systemImage: "text.alignleft") { showingLog = true }
                    Button("Forget unlock code", systemImage: "key.slash", role: .destructive) {
                        connection.forgetResponse()
                    }
                    if let name = connection.boardName {
                        Button("Forget board", systemImage: "trash", role: .destructive) {
                            connection.forget(name)
                        }
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
        .navigationDestination(isPresented: $showingRides) { RidesView() }
        .sheet(isPresented: $addingBoard) {
            NavigationStack {
                ScannerView(onPick: { addingBoard = false })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { addingBoard = false } }
                    }
            }
        }
        .alert("Rename board", isPresented: $renaming) {
            TextField(connection.boardName ?? "Name", text: $draftName)
            Button("Save") { connection.rename(to: draftName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave blank for the serial number.")
        }
    }

    /// The title doubles as a board switcher.
    private var boardPicker: some View {
        Menu {
            ForEach(connection.knownBoards, id: \.self) { name in
                Button {
                    connection.switchTo(name)
                } label: {
                    if name == connection.boardName?.lowercased() {
                        Label(KnownBoards.displayName(for: name), systemImage: "checkmark")
                    } else {
                        Text(KnownBoards.displayName(for: name))
                    }
                }
            }
            Divider()
            Button("Add board", systemImage: "plus") { addingBoard = true }
        } label: {
            HStack(spacing: 4) {
                Text(connection.displayName ?? "Board").font(.headline)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
        }
    }

    @ViewBuilder private var status: some View {
        switch connection.phase {
        case .waiting, .idle, .scanning, .failed:
            offlineRow(icon: "dot.radiowaves.left.and.right", text: "Offline", animate: true)
        case .bluetoothOff:
            offlineRow(icon: "antenna.radiowaves.left.and.right.slash", text: "Bluetooth is off")
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

    private func offlineRow(icon: String, text: String, animate: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: animate)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let seen = connection.lastSeenAt {
                    TimelineView(.everyMinute) { context in
                        Text("Last seen \(seen.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .id(context.date)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 18))
    }

    private var speedAndBattery: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center) {
                if connection.isLive {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(speedText)
                            .font(.system(size: 72, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(useMetric ? "km/h" : "mph")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                } else if let km = connection.rangeKm {
                    // Offline there's no speed; range is what you want to know.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(distance(km: km, decimals: km < 16 ? 1 : 0)?.split(separator: " ").first.map(String.init) ?? "–")
                            .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                        Text("\(useMetric ? "km" : "mi") left")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                BatteryRing(percent: t.batteryPercent ?? 0, tint: batteryTint)
                    .frame(width: 112, height: 112)
            }
            if connection.isLive, let km = connection.rangeKm {
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
                }
            }
        }
        .padding(20)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
    }

    private var chargingCard: some View {
        let session = connection.chargeSession
        let seconds = session?.secondsToFull(packWattHours: t.model.packWattHours)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Charging", systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, options: .repeating)
                    if connection.isToppingOff {
                        Text("Topping off")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                    } else if let seconds, seconds > 0 {
                        Text(Self.duration(seconds))
                            .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("to 90%, about \(Date.now.addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if t.batteryPercent == 100 {
                        Text("Full").font(.system(size: 44, weight: .semibold, design: .rounded))
                    } else {
                        Text("Charging").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                BatteryRing(percent: t.batteryPercent ?? 0, tint: .green)
                    .frame(width: 112, height: 112)
            }
            if let session, session.samples.count > 1 {
                ChargeChart(session: session)
                    .frame(height: 110)
            }
            HStack {
                if let watts = t.chargingWatts {
                    Label(String(format: "%.0f W", watts), systemImage: "bolt.horizontal")
                }
            }
            .font(.caption.monospacedDigit())
        }
        .padding(20)
        .background(.fill.tertiary, in: .rect(cornerRadius: 24))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func errorBanner(_ error: BoardErrorCode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.headline)
                Text(error.advice).font(.subheadline)
                Text("Error \(error.code)").font(.caption).opacity(0.7)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(16)
        .background(.orange.opacity(0.15), in: .rect(cornerRadius: 20))
        .transition(.move(edge: .top).combined(with: .opacity))
        .sensoryFeedback(.warning, trigger: error.code)
    }

    private func faultBanner(_ faults: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Fault", systemImage: "exclamationmark.triangle.fill")
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
                // Switching mode while moving faults the board.
                .disabled((t.speedKPH ?? 0) >= 1)
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
            if let volts = connection.packVolts {
                Stat("Voltage", String(format: "%.1f V", volts), icon: "bolt")
            }
            if !connection.isLive {
            } else if t.usesModernTelemetry, !t.isCharging {
                Stat(t.isRegenerating ? "Regen" : "Power", t.powerWatts.map { abs($0) < 10 ? "Idle" : String(format: "%.0f W", abs($0)) },
                     icon: t.isRegenerating ? "arrow.uturn.backward" : "bolt.horizontal")
            } else if !t.usesModernTelemetry {
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
            if connection.isLive {
                Stat("Pitch", t.pitch.map { String(format: "%.1f°", $0) }, icon: "angle")
            }
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
        guard connection.isLive else { return "–" }
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

/// Battery percentage over the charging session.
private struct ChargeChart: View {
    let session: ChargeSession

    var body: some View {
        let low = max(0, ((session.samples.map(\.percent).min() ?? 0) - 5) / 10 * 10)
        Chart(session.samples) { sample in
            AreaMark(x: .value("Time", sample.date), yStart: .value("Base", low), yEnd: .value("Battery", sample.percent))
                .foregroundStyle(.linearGradient(colors: [.green.opacity(0.35), .green.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", sample.date), y: .value("Battery", sample.percent))
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: low...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: Array(Set([low, 50, 100])).filter { $0 >= low }.sorted()) { value in
                AxisGridLine().foregroundStyle(.white.opacity(0.08))
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
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
            Text(title)
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
