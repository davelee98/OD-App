# OD App — Xcode Setup

## After Cloning

Run once to configure git filters (strips your personal Apple Developer Team ID from commits):

```sh
sh scripts/setup.sh
```

## Create the Xcode Project

1. Open Xcode → **File > New > Project**
2. Choose **iOS > App**
3. Set:
   - Product Name: `OD App`
   - Bundle ID: `com.yourname.od-app`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Minimum Deployment: **iOS 17.0**
4. Save into this directory (overwrite the generated `ContentView.swift` and `<AppName>App.swift`)

## Add the Source Files

In Xcode's Project Navigator, **delete** the generated `ContentView.swift` and app entry file.

Then **File > Add Files to Project** (or drag-and-drop) for these folders:
```
BLE/
Protocol/
Views/
Models/
ODApp.swift
ContentView.swift
```
Check **"Copy items if needed"** and **"Create groups"**.

Replace `Info.plist` contents with the one in this repo (adds Bluetooth usage descriptions).

## Add CryptoSwift (for AES-CCM encrypted commands)

**File > Add Package Dependencies…**
URL: `https://github.com/krzyzanowskim/CryptoSwift`
Version: Up to Next Major from `1.8.0`

CryptoSwift is only needed for the encrypted-command path (`ODSession`). Authentication (AES-128-CMAC) uses CommonCrypto which is built in.

## Required Capabilities

In **Signing & Capabilities**:
- Add **Bluetooth** background mode if you want background updates
  (for foreground-only use, no extra capability is needed)

## File Structure

```
OD App/
├── ODApp.swift               ← @main entry point
├── ContentView.swift         ← Root NavigationStack
├── Info.plist                ← Bluetooth usage strings
├── BLE/
│   ├── ODConstants.swift     ← UUIDs, opcodes, LogEntry
│   ├── BLEManager.swift      ← CBCentralManager, scanning, DiscoveredDevice
│   └── ODDevice.swift        ← CBPeripheral wrapper, command queue
├── Protocol/
│   ├── ODCommands.swift      ← Command packet builders + Data helpers
│   ├── ODAuth.swift          ← AES-128-CMAC auth, PSK keychain storage
│   └── ODConfig.swift        ← TLV config parse/serialize + CRC16-CCITT
├── Views/
│   ├── ScanView.swift        ← BLE scanner + device list
│   ├── DeviceDetailView.swift← Tab container (Configure | BLE Tester)
│   ├── ConfigView.swift      ← Device configuration UI
│   ├── BLETesterView.swift   ← Raw BLE command tester + log
│   └── Components/
│       └── DeviceRowView.swift
└── Models/
    ├── DevicePreset.swift    ← Known hardware presets
    └── ConfigModel.swift     ← ODConfigModel + CRC16
```
