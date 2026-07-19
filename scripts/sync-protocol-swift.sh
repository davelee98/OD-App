#!/usr/bin/env bash
#
# Re-vendor the generated Swift protocol/struct sources from a local opendisplay-protocol checkout
# into Generated/. Mirrors scripts/sync-ble-common.sh (the vendored-JS flow).
#
# Usage: scripts/sync-protocol-swift.sh /path/to/opendisplay-protocol
#
# The files are @generated upstream (tools/gen_swift_structs.py); do not hand-edit. Drift is gated
# in the protocol repo's own CI (`--check`). See Generated/README.md.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 /path/to/opendisplay-protocol" >&2
  exit 2
fi

SRC_REPO="$1"
SRC_DIR="${SRC_REPO}/src"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Generated"

# Generated Swift files to vendor.
FILES=(opendisplay_protocol.swift opendisplay_structs.swift)

for f in "${FILES[@]}"; do
  if [ ! -f "${SRC_DIR}/${f}" ]; then
    echo "error: ${SRC_DIR}/${f} not found — is '${SRC_REPO}' the opendisplay-protocol repo?" >&2
    exit 1
  fi
  echo "==> ${f}"
  cp "${SRC_DIR}/${f}" "${DEST}/${f}"
done

echo "==> Done. Synced ${#FILES[@]} file(s) into ${DEST}."
echo "    Reminder: these are @generated — do not hand-edit; regenerate upstream and re-sync."
