# Protocol / struct constants migration

**Date:** 2026-07-19

Audit of app-side constants and types superseded by the vendored, generated source-of-truth files
(`Generated/opendisplay_protocol.swift`, `Generated/opendisplay_structs.swift` — from the sister
repo `opendisplay-protocol`), and what was rewired vs. deferred.

## Source of truth
- **`Generated/opendisplay_protocol.swift`** — wire constants (opcodes `CMD_*`, responses `RESP_*`,
  `AUTH_STATUS_*`, NACK/NFC/PIPE codes, chunk sizes). **Compiled into the target.**
- **`Generated/opendisplay_structs.swift`** — payload structs, enums (`ColorScheme`, `ICType`,
  `Rotation`, `TransmissionModes`, …), bitfields, and config consts (`OD_CONFIG_*`, CRC).
  **Not yet compiled** (see "Blocked" below).

## ✅ Rewired now (this PR) — protocol constants, zero behavior change

| Site | Before | After |
|---|---|---|
| `OD.configWriteChunkSize` | `200` | `Int(CONFIG_CHUNK_SIZE)` |
| `ODDevice.writeConfig` ACK | `command == 0x41 \|\| 0x42` | `== RESP_CONFIG_WRITE \|\| == RESP_CONFIG_CHUNK` |
| `ODDevice.writeConfig` ACK | `responseType == 0xFF` | `== RESP_NACK` |
| `ODDevice.writeConfig` ACK | `responseType == 0x00` | `== RESP_ACK` |
| `ODDevice` image-chunk log filter | `data[1] == 0x71` | `== UInt8(CMD_DIRECT_WRITE_DATA & 0xFF)` |
| `ODDevice.responseLabel` | `0x00`/`0xFF` | `RESP_ACK`/`RESP_NACK` |

Values are identical, so no wire behavior changes — this just points the native code at the
canonical constants. `OD.Cmd` opcodes stay a Swift enum (raw values must be literals) but are pinned
to the generated `CMD_*` by `ProtocolOpcodeTests`; `configWriteChunkSize` is pinned to the bundled
JS by `BLEChunkSizeTests`, now transitively tying JS ↔ generated ↔ Swift to one value.

## ✅ Done (step 2) — `ColorScheme` retired, structs file compiled in

The app's hand-rolled `enum ColorScheme` was deleted and replaced by the generated one; the app-side
affordances (`displayName`, `appSupported`) live in an `extension ColorScheme` in
`BLE/ODConstants.swift`. `opendisplay_structs.swift` is now compiled into the target (`ColorScheme`
was its only collision). Notes:

- Case names changed (`.blackWhite` → `.mono`, `.sixColor` → `.bwgbry`, …); raw values 0…6 are
  unchanged, so persisted `SavedDisplayEntity.colorScheme` codes and `ImageProcessor`'s raw-code
  keys still work.
- The generated enum adds `sevenColor`/`bwgbrySplit`/`rgb565`/`rgb888`/`rgb16bpc`, so the composer
  picker uses `ColorScheme.appSupported` (the epaper subset 0…6) instead of `.allCases`.
- The dead `bitsPerPixel` (dead-code review §8) was dropped, not ported.
- `ColorSchemeTests` pins `appSupported`, the display names, and raw-value reconstruction.

### ✅ Struct / enum rewires (step 3)
With `opendisplay_structs.swift` compiled in, the constants that have a **native Swift consumer** were
migrated onto the generated types (all zero behavior change, guarded by `AdvertisementDataTests`):

- **`AdvertisementData.swift`** — the fixed 16-byte MSD header now decodes via `MsdAdvertisement(bytes:)`;
  the status byte via `MsdStatusBits` (`.batteryVoltageBit8` / `.rebootFlag` / `.connectionRequested` /
  `mainLoopCounterShift`/`Mask`); and the config-overlay magic numbers via `ConfigPacketType`
  (`.sensor`/`.binaryInput`/`.touch`), `SensorType` (`.sht40`/`.bq27220`), and `TouchIcType` (`.gt911`).
- **`ConfigModel.swift`** — the packet-type accessors (`value`/`integer`/`set`) now take a
  `ConfigPacketType` (`.display` = 32, `.power` = 4, `.security` = 39) instead of magic integers.

### Nothing to migrate (no native Swift consumer)
- **Config structs** (`SystemConfig`, `DisplayConfig`, `WifiConfig`, …): the app never (de)serializes
  config natively — `ODConfigModel` reads JS-decoded `ToolboxPacket` **string fields**, so there is no
  Swift struct-parse to replace.
- **`OD_CONFIG_CRC_POLY` / `OD_CONFIG_CRC_INIT`**: the config CRC is computed in the JS layer, not Swift.
- **`OD_CONFIG_VERSION` / `OD_CONFIG_MINOR_VERSION`**: `ToolboxData.version`/`.minorVersion` is the
  **config.yaml schema** version (a different concept) and is authored on the website — not the wire
  `OD_CONFIG_*`.
- **`TransmissionModes`** (the OptionSet): the app forwards the raw `transmission_modes` byte to the JS
  layer and does no Swift bit-checking, so there is no `.contains(...)` site to rewire.

## 🗑️ Deleted, not rewired — dead + stale ✅
The NFC command builders (`ODCommands.nfcWriteSingle/Start/Chunk/End`, `ODDevice.writeNFC`,
`Data.chunked`) used the old `0x0082 + 0x01/0x10/0x11/0x12` framing — **unused** (dead-code review §6)
*and* stale vs. the generated `NFC_SUB_*` / v2.0 endpoint. **Removed** rather than rewired.
`OD.Cmd.nfc` (the bare opcode, now `0x0083`) is kept — it's still used by the BLE Tester and pinned
by `ProtocolOpcodeTests`.
