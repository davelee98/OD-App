# OpenDisplay iOS App

A native iOS companion app for [OpenDisplay](https://opendisplay.org) e-ink devices, providing Bluetooth Low Energy (BLE) configuration, image uploading, and device control.

## Why a native app?

The OpenDisplay web tools (Toolbox and Display Tool) run in a browser and communicate with devices over BLE using the Web Bluetooth API. **Mobile Safari blocks Web Bluetooth entirely**, making those tools unusable on iPhone and iPad. This app replicates the full feature set of both web tools as native SwiftUI views, with no browser required.

---

## Features

### Toolbox
Configure and manage OpenDisplay hardware:
- **Hardware wizard** — select your board (reTerminal, ESP32-S3, XIAO, etc.) and display panel (7.5", 2.9", 4.2", 9.7") to auto-fill resolution and color scheme
- **Display configuration** — set width, height, color mode, refresh mode, and deep sleep
- **Security** — lock the device with a random 128-bit PSK stored in the iOS Keychain; AES-128-CMAC authentication + optional AES-CCM session encryption
- **WiFi** — configure SSID and password
- **Device actions** — Read Config, Write Config, Reboot, Enter DFU / Bootloader
- **Status log** — color-coded (info / success / error) timestamped log of all operations

### Display Tool
Upload images and control the display in real time:
- **Canvas** — shows the current image at the correct aspect ratio for the connected display
- **Draw mode** — freehand drawing directly on the canvas with color and line-width picker
- **Text mode** — tap to place text overlays; drag to reposition; configurable size and color
- **QR Code mode** — generate and place QR codes from any URL
- **Image picker** — choose a photo from your library; live dithering preview updates as you change settings
- **Dithering** — eight algorithms: None, Floyd-Steinberg, Atkinson, Stucki, Sierra, Sierra Lite, Burkes, Jarvis-Judice-Ninke
- **Color schemes** — B/W, B/W+Red, B/W+Yellow, B/W+R+Y, 6-color Spectra, 4-gray, 16-gray
- **Upload** — raw deflate compressed image sent over BLE in 20-byte chunks with progress indicator
- **Device controls** — Reboot, Deep Sleep, Enter DFU
- **Debug** — send raw hex BLE commands; recent log entries visible inline

### BLE Tester
Low-level command interface:
- Send arbitrary BLE commands by opcode
- Live notification log with hex and ASCII display

---

## Project Structure

```
OD App/
├── ODApp.swift                  ← @main entry point
├── ContentView.swift            ← Root NavigationStack
├── Info.plist                   ← Bluetooth usage strings
├── Assets.xcassets/             ← App icon + ODLogo image set
├── BLE/
│   ├── BLEManager.swift         ← CBCentralManager: scanning, connecting
│   ├── ODDevice.swift           ← CBPeripheral wrapper, serial command queue, upload progress
│   └── ODConstants.swift        ← Service/characteristic UUIDs, all opcodes, ColorScheme enum
├── Protocol/
│   ├── ODCommands.swift         ← Binary packet builders for every command
│   ├── ODAuth.swift             ← AES-128-CMAC handshake, PSK Keychain storage, AES-CCM session
│   └── ODConfig.swift           ← TLV config parse/serialize, CRC16-CCITT
├── Models/
│   ├── ConfigModel.swift        ← ODConfigModel (display settings, WiFi, security)
│   ├── DevicePreset.swift       ← Known hardware dimension presets
│   └── ImageProcessor.swift     ← Dithering engine, palette quantization, wire-format packing, deflate
└── Views/
    ├── ScanView.swift           ← BLE scanner, device list, Bluetooth state handling
    ├── DeviceDetailView.swift   ← Tab container (Toolbox | Display | BLE Tester)
    ├── ToolboxView.swift        ← Hardware wizard + full device configuration
    ├── DisplayToolView.swift    ← Canvas, image upload, device controls
    ├── BLETesterView.swift      ← Raw BLE command tester
    ├── ODLogoView.swift         ← Reusable logo widget shown in every navigation bar
    └── Components/
        └── DeviceRowView.swift  ← Device row shown in the scan list
```

---

## BLE Protocol

OpenDisplay devices advertise with a name prefix of `OD` and expose a single BLE service and characteristic at UUID `0x2446`. All communication is command-response over that one characteristic: the app writes a command packet and (for commands that return data) reads the response from a notification.

Commands are framed as:
```
[2-byte opcode LE] [payload bytes…]
```

Config data uses a TLV (Type-Length-Value) format with a CRC16-CCITT trailer. Authentication uses AES-128-CMAC; an optional encrypted session uses AES-CCM with a per-session nonce.

---

## Requirements

| Requirement | Version |
|---|---|
| Xcode | 15 or later |
| iOS deployment target | 17.0 |
| Swift | 5 |
| Physical device | Required (Simulator has no Bluetooth) |

---

## How to Compile in Xcode

### 1. Clone the repository

```sh
git clone <repo-url>
cd "OD App"
```

### 2. Open the project

Double-click **`OD App.xcodeproj`** in Finder, or from Terminal:

```sh
open "OD App.xcodeproj"
```

### 3. Add the CryptoSwift package

The app uses [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) for AES-128-CMAC and AES-CCM encryption. Add it once after cloning:

1. In Xcode, go to **File → Add Package Dependencies…**
2. Paste the URL: `https://github.com/krzyzanowskim/CryptoSwift`
3. Set **Dependency Rule** to *Up to Next Major Version* from `1.8.0`
4. Click **Add Package**, then choose **CryptoSwift** as the library to link to the `OD App` target

### 4. Set your development team

1. In the Project Navigator, click the **OD App** project (top of the file tree)
2. Select the **OD App** target → **Signing & Capabilities** tab
3. Set **Team** to your Apple Developer account

Xcode will automatically manage provisioning profiles. A free Apple ID works for testing on your own device (7-day certificate); a paid developer account is needed for distribution.

### 5. Select a run destination

In the toolbar at the top of Xcode, click the device selector and choose your connected iPhone or iPad. **Bluetooth is not available in the iOS Simulator** — you must run on a physical device.

If your device is not listed:
- Connect it with a USB cable
- Unlock it and tap **Trust** when prompted
- Wait for Xcode to finish indexing symbols (progress bar in the top center)

### 6. Build and run

Press **⌘R** (or click the **▶ Run** button).

Xcode will compile the project, install it on your device, and launch it automatically. The first time you run, iOS will ask you to trust the developer certificate:

> **Settings → General → VPN & Device Management → [Your Apple ID] → Trust**

After trusting, re-launch the app from the home screen or press **⌘R** again in Xcode.

### 7. Pair with an OpenDisplay device

1. Make sure the OpenDisplay device is powered on and advertising
2. In the app, tap **Scan** — nearby devices with the `OD` name prefix will appear
3. Tap a device to connect; the Toolbox tab opens automatically
4. Use **Read Config** to pull the current device configuration

---

## Troubleshooting

| Issue | Fix |
|---|---|
| "Build Failed" — missing CryptoSwift | Re-add the package via File → Add Package Dependencies (step 3 above) |
| Device not appearing in Xcode | Reconnect USB cable; unlock device; check Window → Devices and Simulators |
| Bluetooth permission denied | Settings → Privacy & Security → Bluetooth → enable for OD App |
| No OD devices found when scanning | Ensure the display device is on and within ~10 m; try stopping and restarting the scan |
| App crashes on launch in Simulator | Run on a physical device — Simulator has no CoreBluetooth support |
