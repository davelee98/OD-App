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

## ⚠️ Not yet in the compile target

Both files are vendored **but not added to the "OD App" target's Sources** — this is the
vendoring/scaffolding step; wiring them in is a follow-up migration PR. Their situations differ:

- **`opendisplay_protocol.swift` — collision-free.** Its flat `CMD_*` / `RESP_*` / `AUTH_*`
  constants don't clash with anything in the app (opcodes there are namespaced under `OD.Cmd`).
  It can be added to the target as-is; the migration then repoints `OD.Cmd`/`ODConstants` usages
  onto these constants. Notably it carries `CMD_NFC_ENDPOINT = 0x0083` — the correct opcode the
  app's `OD.Cmd.nfc = 0x0082` is two protocol versions stale against.
- **`opendisplay_structs.swift` — one collision.** It defines `public enum ColorScheme`, which
  collides with the app's hand-rolled `enum ColorScheme` in `BLE/ODConstants.swift` (the duplicated
  color-enum the protocol repo's `docs/shared-types-plan.md` flags). Compiling both into one module
  is an "invalid redeclaration" error, so the app's `ColorScheme` must be retired first.

**Migration follow-up** (separate PR): add `opendisplay_protocol.swift` to the target and repoint
opcode usages; retire the hand-rolled `ColorScheme` (and, over time, `TransmissionModes`, the config
structs, and the MSD-advertisement parsing) onto the generated types, repoint call sites
(`ContentView`, `ComposerView`), then add `opendisplay_structs.swift` to the target.
