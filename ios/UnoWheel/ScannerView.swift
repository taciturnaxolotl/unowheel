import SwiftUI

struct ScannerView: View {
    @Environment(BoardConnection.self) private var connection
    /// Set when shown as the "Add board" sheet; called after picking.
    var onPick: (() -> Void)?

    private var boards: [DiscoveredBoard] {
        guard onPick != nil else { return connection.nearby }
        return connection.discovered.filter { $0.name.lowercased() != connection.boardName?.lowercased() }
    }

    var body: some View {
        List {
            switch onPick == nil ? connection.phase : (connection.phase == .bluetoothOff ? .bluetoothOff : .idle) {
            case .bluetoothOff:
                ContentUnavailableView("Bluetooth is off", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Turn on Bluetooth to connect."))
            case .failed(let message):
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            case .waiting(let name):
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waiting for \(KnownBoards.displayName(for: name))").font(.headline)
                            Text("Turn it on to connect.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            default:
                EmptyView()
            }

            Section {
                if boards.isEmpty && connection.phase != .bluetoothOff && (onPick != nil || !connection.isWaiting) {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Searching")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(boards) { board in
                    Button {
                        connection.connect(board)
                        onPick?()
                    } label: {
                        HStack {
                            Image(systemName: "circle.circle")
                                .font(.title2)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(board.displayName).font(.headline)
                                Text(board.displayName == board.name
                                     ? (board.known ? "Known" : "New")
                                     : board.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if board.rssi != 0 {
                                SignalBars(rssi: board.rssi)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } header: {
                Text("Nearby")
            } footer: {
                Text("Missing? Close the Onewheel app.")
            }
        }
        .navigationTitle(onPick == nil ? "UnoWheel" : "Add board")
        .refreshable { connection.startScan() }
        .onAppear { connection.startScan() }
        .onDisappear { connection.stopScan() }
    }
}

struct SignalBars: View {
    let rssi: Int

    private var level: Int {
        switch rssi {
        case (-60)...: 3
        case (-75)...: 2
        default: 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .frame(width: 4, height: CGFloat(4 + bar * 4))
                    .opacity(bar <= level ? 1 : 0.25)
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Signal \(level) of 3")
    }
}
