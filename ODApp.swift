import SwiftUI
import SwiftData

@main
struct ODApp: App {
    /// One shared BLE manager for the whole app (the old build made a fresh one per tool).
    @StateObject private var bleManager = BLEManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(bleManager)
        }
        .modelContainer(for: SavedDisplayEntity.self)
    }
}

private struct RootView: View {
    @State private var showSplash = true
    @State private var dismissWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            ContentView()
            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .contentShape(Rectangle())
                    .onTapGesture { dismissSplash() }
            }
        }
        .onAppear {
            guard dismissWorkItem == nil else { return }
            let work = DispatchWorkItem { dismissSplash() }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    private func dismissSplash() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        withAnimation { showSplash = false }
    }
}
