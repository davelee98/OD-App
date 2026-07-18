#!/usr/bin/env bash
#
# Re-vendor EpaperDithering.xcframework from a local epaper-dithering checkout.
#
# Usage: scripts/sync-dither-xcframework.sh /path/to/epaper-dithering
#
# Builds the XCFramework in the source repo (if not already built) and copies it into
# Frameworks/. See Frameworks/README.md for context. Mirrors the vendoring discipline used
# for Resources/ble-common.js (scripts/sync-ble-common.sh).
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 /path/to/epaper-dithering" >&2
  exit 2
fi

SRC_REPO="$1"
CRATE_DIR="${SRC_REPO}/packages/rust/ios"
XCF="${CRATE_DIR}/EpaperDithering.xcframework"
DEST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Frameworks"

if [ ! -d "${CRATE_DIR}" ]; then
  echo "error: ${CRATE_DIR} not found — is '${SRC_REPO}' the epaper-dithering repo?" >&2
  exit 1
fi

if [ ! -d "${XCF}" ]; then
  echo "==> XCFramework not built yet; building it"
  "${CRATE_DIR}/build-xcframework.sh"
fi

echo "==> Syncing ${XCF} -> ${DEST}"
rm -rf "${DEST}/EpaperDithering.xcframework"
cp -R "${XCF}" "${DEST}/"

echo "==> Done. Remember to:"
echo "    - update the core version noted in Frameworks/README.md"
echo "    - run the OD AppTests parity test (RustDitherParityTests) and keep it green"
