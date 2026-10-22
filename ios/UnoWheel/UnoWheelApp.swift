import SwiftUI

@main
struct UnoWheelApp: App {
    @State private var connection = BoardConnection()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(connection)
                #if DEBUG
                .task {
                    if CommandLine.arguments.contains("-demo") { connection.loadDemo() }
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: connection.appBecameActive()
                    case .background: connection.appEnteredBackground()
                    default: break
                    }
                }
        }
    }
}

struct RootView: View {
    @Environment(BoardConnection.self) private var connection

    var body: some View {
        NavigationStack {
            Group {
                // Once a board is known, its screen is home; the list only
                // shows on first run.
                if connection.boardName != nil {
                    BoardView()
                } else {
                    ScannerView()
                }
            }
        }
        .animation(.default, value: connection.boardName == nil)
    }
}
