import SwiftUI

struct DeviceRowView: View {
    let device: DiscoveredDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.caption)
                    Text(device.rssiDescription)
                        .font(.caption)
                }
                .foregroundStyle(rssiColor)

                connectionBadge
            }
        }
        .padding(.vertical, 4)
    }

    private var rssiColor: Color {
        switch device.signalStrength {
        case .good: return .green
        case .fair: return .orange
        case .weak: return .red
        }
    }

    private var connectionBadge: some View {
        Group {
            switch device.connectionState {
            case .disconnected:
                EmptyView()
            case .connecting:
                ProgressView().scaleEffect(0.7)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}
