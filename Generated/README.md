# Generated

Machine-generated Swift source **vendored from the sister repo `opendisplay-protocol`** — the
single source of truth for the OpenDisplay BLE wire protocol. **Do not hand-edit anything here;**
edit the canonical header upstream and regenerate.

## Contents

| File | Upstream source | Generator |
|---|---|---|
| `opendisplay_protocol.swift` | `opendisplay-protocol/src/opendisplay_protocol.h` (`OD_PROTOCOL_VERSION 2.0`) | `tools/gen_swift_protocol.py` |
| `opendisplay_structs.swift` | `opendisplay-protocol/src/opendisplay_structs.h` (`OD_STRUCTS_VERSION 2.0`) | `tools/gen_swift_structs.py` |

`opendisplay_protocol.swift` is the wire-protocol constants (opcodes, response/auth/NACK bytes) as
flat `public let`s. `opendisplay_structs.swift` is the payload structs/enums/bitfields.

Each file carries a `// @generated … DO NOT EDIT` header with the source header's SHA-256. Drift is
gated upstream in the protocol repo's CI (`--check`), which is the canonical place for the check —
the same discipline as the firmware header vendoring.

## Updating

```sh
scripts/sync-protocol-swift.sh /path/to/opendisplay-protocol
```

## Compiled into the target

Both files are now in the "OD App" target's Sources:

- **`opendisplay_protocol.swift`** — compiled in; native protocol constants (`RESP_*`, `CMD_*`,
  `CONFIG_CHUNK_SIZE`, …) are used directly by `ODDevice`/`ODConstants`, and `OD.Cmd` is pinned to
  the generated `CMD_*` by `ProtocolOpcodeTests`. This fixed the stale `OD.Cmd.nfc` opcode
  (`0x0082` → `CMD_NFC_ENDPOINT 0x0083`).
- **`opendisplay_structs.swift`** — compiled in; the app's hand-rolled `ColorScheme` was retired in
  favor of the generated enum (app-side `displayName` / `appSupported` live in an extension in
  `BLE/ODConstants.swift`), pinned by `ColorSchemeTests`.

### Still hand-maintained (future rewires onto the generated structs)
`TransmissionModes`, the config structs, and the MSD-advertisement parsing (`AdvertisementData.swift`)
still have hand-written forms; migrating them onto `ManufacturerData`/`MsdAdvertisement`/the config
structs/enums here is the remaining work. See `docs/protocol-constants-migration.md`.
