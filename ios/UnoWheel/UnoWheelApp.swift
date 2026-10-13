import SwiftUI

@main
struct UnoWheelApp: App {
    @State private var connection = BoardConnection()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                #if DEBUG
                .task {
                    if CommandLine.arguments.contains("-demo") { connection.loadDemo() }
                }
                #endif
        }
    }
}

struct RootView: View {
    @Environment(BoardConnection.self) private var connection

    var body: some View {
        NavigationStack {
            Group {
                if connection.isConnected {
                    BoardView()
                } else {
                    ScannerView()
                }
            }
        }
        .animation(.default, value: connection.isConnected)
    }
}
