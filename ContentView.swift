import SwiftUI

enum AppTool: String, Hashable {
    case toolbox = "Toolbox"
    case bleTester = "BLE Tester"

    var systemImage: String {
        switch self {
        case .toolbox: "wrench.and.screwdriver"
        case .bleTester: "antenna.radiowaves.left.and.right"
        }
    }
}

struct ContentView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()

                ODLogoView(height: 104)
                    .padding(.bottom, 24)

                ForEach([AppTool.toolbox, .bleTester], id: \.self) { tool in
                    NavigationLink(value: tool) {
                        Label(tool.rawValue, systemImage: tool.systemImage)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding(.horizontal, 32)
            .navigationDestination(for: AppTool.self) { tool in
                ToolFlowView(tool: tool)
            }
        }
    }
}

private struct ToolFlowView: View {
    let tool: AppTool
    @StateObject private var bleManager = BLEManager()

    var body: some View {
        Group {
            switch tool {
            case .toolbox:
                ToolboxView()
            case .bleTester:
                DisplayToolView()
            }
        }
        .environmentObject(bleManager)
    }
}
