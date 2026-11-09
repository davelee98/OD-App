import AVFoundation
import SwiftUI
import ODProtocolKit

// MARK: - Unlock section

/// Inline "this display is encrypted" form, shown wherever a connected display is waiting on a key
/// (`ODDevice.keyPrompt`). Accepts the 32-hex key or the `opendisplay.org/l/?…` link from the
/// display's on-screen QR code — typed, pasted, or scanned with the camera.
struct UnlockDisplaySection: View {
    @ObservedObject var device: ODDevice
    @State private var input = ""
    @State private var inputError: String?
    @State private var showScanner = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Display is encrypted", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Scan the QR code the display is showing, or enter its 32-character key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                showScanner = true
            } label: {
                Label("Scan Display QR Code", systemImage: "qrcode.viewfinder")
            }
            .disabled(device.isUnlocking)
            TextField("Key or QR link", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .font(.callout.monospaced())
                .submitLabel(.go)
                .onSubmit { submit(input) }
                .onChange(of: input) { _, _ in inputError = nil }
            if let message = inputError ?? rejectionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                submit(input)
            } label: {
                HStack {
                    Text(device.isUnlocking ? "Unlocking…" : "Unlock")
                    if device.isUnlocking { Spacer(); ProgressView() }
                }
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || device.isUnlocking)
        } footer: {
            Text("The key is saved in your Keychain for this display, so you only need to do this once.")
        }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet(prompt: "Point the camera at the QR code on \(device.name).") { payload in
                showScanner = false
                submit(payload)
            }
        }
    }

    private var rejectionMessage: String? {
        if case .rejected(let reason) = device.keyPrompt { return reason }
        return nil
    }

    private func submit(_ text: String) {
        switch DisplayKeyInput.resolve(text, for: device.name) {
        case .success(let key):
            inputError = nil
            device.unlock(with: key)
        case .failure(let error):
            inputError = error.message
        }
    }
}

/// Modal form of `UnlockDisplaySection`, for surfaces that aren't a `Form` (the Composer).
struct UnlockDisplaySheet: View {
    @ObservedObject var device: ODDevice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { UnlockDisplaySection(device: device) }
                .navigationTitle("Unlock Display")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Not Now") { dismiss() } }
                }
        }
        .onChange(of: device.keyPrompt) { _, prompt in if prompt == nil { dismiss() } }
    }
}

// MARK: - Input resolution

/// Turns a typed/pasted/scanned string into a key for one specific display.
enum DisplayKeyInput {
    struct Problem: Error, Equatable { let message: String }

    static func resolve(_ text: String, for advertisedName: String?) -> Result<Data, Problem> {
        guard let entry = ODKeyEntry.parse(text) else {
            return .failure(Problem(message: "Enter the 32-character hex key, or scan the display's QR code."))
        }
        switch entry {
        case .key(let key):
            return .success(key)
        case .link(let link):
            guard link.matches(advertisedName: advertisedName) else {
                return .failure(Problem(message: "That QR code belongs to \(link.deviceName), not \(advertisedName ?? "this display")."))
            }
            guard let key = link.encryptionKey else {
                return .failure(Problem(message: "This QR code doesn't include a key. The display hides it unless \"show key on screen\" is enabled in its security settings."))
            }
            return .success(key)
        }
    }
}

// MARK: - Camera scanner

/// Full-screen camera sheet that reports the first QR payload it reads.
struct QRScannerSheet: View {
    let prompt: String
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                switch access {
                case .authorized:
                    if AVCaptureDevice.default(for: .video) != nil {
                        QRScannerView(onFound: onFound).ignoresSafeArea()
                        Text(prompt)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    } else {
                        ContentUnavailableView("No Camera", systemImage: "camera",
                                               description: Text("This device has no camera. Paste the key or link instead."))
                    }
                case .notDetermined:
                    ProgressView()
                        .task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            access = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                default:
                    ContentUnavailableView {
                        Label("Camera Access Off", systemImage: "camera.fill")
                    } description: {
                        Text("Allow camera access in Settings to scan a display's QR code.")
                    } actions: {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Camera QR reader (ported from OD-Badge). Reports the first payload it recognises, once.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var hasReported = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.bounds
            view.layer.addSublayer(layer)
            preview = layer

            // startRunning blocks; keep it off the main thread.
            Task.detached { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            Task.detached { [session] in session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !hasReported,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue
            else { return }
            hasReported = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onFound?(value)
        }
    }
}
