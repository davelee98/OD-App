# Generated

Machine-generated Swift source **vendored from the sister repo `opendisplay-protocol`** — the
single source of truth for the OpenDisplay BLE wire protocol. **Do not hand-edit anything here;**
edit the canonical header upstream and regenerate.

## Contents

| File | Upstream source | Generator |
|---|---|---|
| `opendisplay_structs.swift` | `opendisplay-protocol/src/opendisplay_structs.h` (`OD_STRUCTS_VERSION 2.0`) | `tools/gen_swift_structs.py` |

Each file carries a `// @generated … DO NOT EDIT` header with the source header's SHA-256. Drift is
gated upstream in the protocol repo's CI (`gen_swift_structs.py --check`), which is the canonical
place for the check — the same discipline as the firmware header vendoring.

## Updating

```sh
scripts/sync-protocol-swift.sh /path/to/opendisplay-protocol
```

## ⚠️ Not yet in the compile target

`opendisplay_structs.swift` is currently vendored **but not added to the "OD App" target's Sources**,
because it defines `public enum ColorScheme` which collides with the app's existing
`enum ColorScheme` in `BLE/ODConstants.swift` (a duplicated color-enum home the protocol repo's
`docs/shared-types-plan.md` explicitly flags). Compiling both into one module is an
"invalid redeclaration" error.

**Migration follow-up** (separate PR): retire the hand-rolled `ColorScheme` (and, over time, the
other hand-maintained wire types — `TransmissionModes`, the config structs, the MSD advertisement
parsing) in favor of these generated types, repoint the call sites (`ContentView`, `ComposerView`),
then add this file to the target. A generated `opendisplay_protocol.swift` (opcodes/responses) is
the intended companion once `gen_swift_protocol.py` exists upstream.
