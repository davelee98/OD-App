# Generated → moved to ODProtocolKit

The machine-generated Swift wire-protocol sources (`opendisplay_protocol.swift`,
`opendisplay_structs.swift`, vendored from the sister repo `opendisplay-protocol`) now live in the
native protocol library, **not here**:

- `Packages/ODProtocolKit/Sources/ODProtocolKit/Generated/`

They are single-sourced there so the package and the app share one copy of the wire types
(`CMD_*`, `ColorScheme`, `ConfigPacketType`, `MsdAdvertisement`, `TransmissionModes`, …). App code
gets them via `import ODProtocolKit`.

Re-vendor with `scripts/sync-protocol-swift.sh /path/to/opendisplay-protocol` (its `DEST` now points
at the package). Still `@generated` — do not hand-edit; regenerate upstream and re-sync. Drift is
gated in the protocol repo's CI.
