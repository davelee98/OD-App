import SwiftUI

struct DeviceDetailView: View {
    @ObservedObject var device: ODDevice
    @EnvironmentObject private var ble: BLEManager
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ToolboxView()
                .tabItem { Label("Toolbox", systemImage: "wrench.and.screwdriver") }
                .tag(0)

            DisplayToolView()
                .tabItem { Label("BLE Tester", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(1)
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ODLogoView()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { ble.disconnect() } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                    Button(role: .destructive) { device.reboot() } label: {
                        Label("Reboot Device", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { device.sendDeepSleep() } label: {
                        Label("Deep Sleep", systemImage: "moon.zzz")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { device.lastError != nil },
            set: { if !$0 { device.lastError = nil } }
        )) {
            Button("OK") { device.lastError = nil }
        } message: {
            Text(device.lastError ?? "")
        }
    }
}
