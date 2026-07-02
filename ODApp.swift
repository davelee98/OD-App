import SwiftUI
import SwiftData

@main
struct ODApp: App {
    /// One shared BLE manager for the whole app (the old build made a fresh one per tool).
    @StateObject private var bleManager = BLEManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
        }
        .modelContainer(for: SavedDisplayEntity.self)
    }
}
