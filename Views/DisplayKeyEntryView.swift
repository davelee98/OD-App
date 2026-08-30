import SwiftUI

/// Enter the encryption key for a locked display, authenticate, and — only on success — persist it.
///
/// Holds the device as an `@ObservedObject` so the in-flight spinner and the rate-limit cooldown
/// track `authPhase` without any plumbing from the parent. Shared by the Add-Display sheet, the
/// Toolbox connection section, and the Composer recovery sheet so all three behave identically.
struct DisplayKeyEntryView: View {
    @ObservedObject var device: ODDevice

    /// Called after the key is accepted and stored, for parents that want to dismiss a sheet.
    var onUnlocked: (() -> Void)?

    @State private var keyHex = ""
    @State private var isRevealed = false
    @State private var errorMessage: String?
    /// Drives a re-render each second while a rate-limit cooldown is counting down. A stored `Date`
    /// alone would leave the button disabled until some unrelated publication happened to redraw.
    @State private var now = Date()

    private let cooldownTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var parsedKey: Data? {
        guard keyHex.count == 32 else { return nil }
        return Data(hexString: keyHex)
    }

    /// Recomputed against `now` rather than read once, so the countdown actually advances.
    private var cooldownRemaining: Int? {
        _ = now
        guard let remaining = device.authCooldownRemaining else { return nil }
        return Int(remaining.rounded(.up))
    }

    private var isBusy: Bool { device.authPhase == .authenticating }

    private var canSubmit: Bool {
        parsedKey != nil && !isBusy && cooldownRemaining == nil && device.connectionState == .connected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            keyField
            counterRow

            if let cooldownRemaining {
                // The device rate-limits attempts, so retrying immediately makes things worse.
                Label("Too many attempts. Try again in \(cooldownRemaining)s.",
                      systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if device.connectionState != .connected {
                Text("Connect to the display to unlock it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: unlock) {
                HStack(spacing: 6) {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "lock.open")
                    }
                    Text(isBusy ? "Unlocking…" : "Unlock Display")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
        }
        .onReceive(cooldownTick) { tick in
            // Only churn while a cooldown is actually running.
            if device.authCooldownRemaining != nil { now = tick }
        }
    }

    @ViewBuilder
    private var keyField: some View {
        HStack(spacing: 6) {
            // Secured by default: the field holds a full credential, and the display is often shown
            // to someone else while it's being set up. The reveal toggle covers hand-transcription,
            // which is how these 32-character keys usually get entered.
            Group {
                if isRevealed {
                    TextField("32-character encryption key", text: $keyHex)
                } else {
                    SecureField("32-character encryption key", text: $keyHex)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .font(.caption.monospaced())
            .onChange(of: keyHex) { _, newValue in
                let filtered = String(newValue.lowercased().filter(\.isHexDigit).prefix(32))
                if filtered != newValue { keyHex = filtered }
                errorMessage = nil
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isRevealed ? "Hide key" : "Show key")
        }
    }

    private var counterRow: some View {
        Text("\(keyHex.count)/32")
            .font(.caption2)
            .foregroundStyle(keyHex.count == 32 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
    }

    private func unlock() {
        guard let key = parsedKey else { return }
        errorMessage = nil
        device.unlock(psk: key) { result in
            switch result {
            case .success:
                keyHex = ""
                isRevealed = false
                onUnlocked?()
            case .failure(let error):
                // Reads as a real sentence now that ODProtocolError conforms to LocalizedError —
                // e.g. "Authentication failed: wrong key."
                errorMessage = error.localizedDescription
                now = Date()   // surface a cooldown immediately if that's what came back
            }
        }
    }
}
