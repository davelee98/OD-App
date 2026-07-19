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

## ⛔ Blocked — needs the structs file compiled in first

`opendisplay_structs.swift` can't be added to the target until the app's hand-rolled `ColorScheme`
is retired (invalid-redeclaration collision). And that retirement is **not a clean swap**:

- Generated `ColorScheme` uses different case names (`mono` vs `blackWhite`, `bwr` vs
  `blackWhiteRed`, …), adds five cases (`sevenColor`, `bwgbrySplit`, `rgb565/888/16bpc`), and has no
  `Identifiable` / `displayName` / `bitsPerPixel`.
- `ComposerView`'s `ForEach(ColorScheme.allCases)` picker would then render the non-epaper RGB cases.

**Follow-up PR (step 2):** repoint `.blackWhite`→`.mono` etc. across `ContentView`/`ComposerView`/
`ImageProcessor`, add `displayName`/`bitsPerPixel`/`Identifiable` as an extension on the generated
enum, restrict the picker to the epaper subset, delete the app's `ColorScheme`, then compile
`opendisplay_structs.swift` in. Once compiled in, these further rewires unlock:

- `OD_CONFIG_VERSION` / `OD_CONFIG_MINOR_VERSION` / `OD_CONFIG_CRC_POLY` / `OD_CONFIG_CRC_INIT` —
  note `ToolboxData.minorVersion` is the **config.yaml schema** version, a *different* concept from
  the wire `OD_CONFIG_MINOR_VERSION`; verify before wiring (they may legitimately differ).
- `ManufacturerData` / `MsdAdvertisement` structs → retire the hand-parse in
  `AdvertisementData.swift`.
- `ICType` / `Rotation` / `TransmissionModes` / `PowerMode` / enums consumed by `ConfigModel` /
  `ToolboxData`.

## 🗑️ Delete, don't rewire — dead + stale
The NFC command builders (`ODCommands.nfcWriteSingle/Start/Chunk/End`, `ODDevice.writeNFC`,
`Data.chunked`) use the old `0x0082 + 0x01/0x10/0x11/0x12` framing. They're **unused** (dead-code
review §6) *and* the sub-protocol is stale vs. the generated `NFC_SUB_*` / v2.0 endpoint. Remove them
rather than rewire (tracked in `docs/dead-code-review.md`).
