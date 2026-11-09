#!/usr/bin/env bash
#
# Re-vendor Frameworks/EpaperDithering.xcframework.
#
# Usage:
#   scripts/sync-dither-xcframework.sh <version>
#       Download the epaper-dithering-ios <version> release (e.g. 1.0.1) from GitHub, verify
#       its SwiftPM checksum, and vendor it. This is the normal path.
#   scripts/sync-dither-xcframework.sh --from-source /path/to/epaper-dithering
#       Build from a local checkout instead (for testing unreleased FFI changes). The result is
#       recorded as an unreleased build; re-vendor from a release before merging.
#
# Either way, Frameworks/EpaperDithering.release records where the framework came from, so a
# re-vendor shows up in review as a version/checksum change. See Frameworks/README.md.
set -euo pipefail

REPO="OpenDisplay/epaper-dithering"
ASSET="EpaperDithering.xcframework.zip"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ROOT}/Frameworks"
XCF_NAME="EpaperDithering.xcframework"
RECORD="${DEST}/EpaperDithering.release"
EXPECTED_ABI_LINE="ABI version of this wrapper (currently 2"

usage() {
  sed -n 3,14p "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Sanity-check an XCFramework before it replaces the vendored one.
verify_xcframework() {
  local xcf="$1"
  for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    [ -f "${xcf}/${slice}/libepaper_dithering_ios.a" ] || {
      echo "error: ${xcf} has no ${slice} slice" >&2; exit 1; }
    [ -f "${xcf}/${slice}/Headers/epaper_dithering.h" ] || {
      echo "error: ${xcf} has no ${slice} header" >&2; exit 1; }
  done
  # RustDither.swift calls the ABI-2 surface (ed_dither_options); refuse anything else.
  grep -q "${EXPECTED_ABI_LINE}" "${xcf}/ios-arm64/Headers/epaper_dithering.h" || {
    echo "error: ${xcf} is not FFI ABI 2 (expected '${EXPECTED_ABI_LINE}' in the header)." >&2
    echo "       Update Models/RustDither.swift and EXPECTED_ABI_LINE together for a new ABI." >&2
    exit 1; }
}

install_xcframework() {
  local xcf="$1"
  echo "==> Installing into ${DEST}/${XCF_NAME}"
  rm -rf "${DEST:?}/${XCF_NAME}"
  cp -R "${xcf}" "${DEST}/"
}

case "${1:-}" in
  ""|-h|--help)
    usage
    ;;

  --from-source)
    [ $# -eq 2 ] || usage
    SRC_REPO="$(cd "$2" && pwd)"
    CRATE_DIR="${SRC_REPO}/packages/rust/ios"
    [ -d "${CRATE_DIR}" ] || {
      echo "error: ${CRATE_DIR} not found — is '$2' the epaper-dithering repo?" >&2; exit 1; }
    echo "==> Building ${XCF_NAME} from ${SRC_REPO}"
    "${CRATE_DIR}/build-xcframework.sh"
    verify_xcframework "${CRATE_DIR}/${XCF_NAME}"
    install_xcframework "${CRATE_DIR}/${XCF_NAME}"
    COMMIT="$(git -C "${SRC_REPO}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    DIRTY="$(git -C "${SRC_REPO}" status --porcelain -- packages/rust 2>/dev/null | head -1)"
    cat > "${RECORD}" <<EOF
# Written by scripts/sync-dither-xcframework.sh — do not edit by hand.
source=local build of ${REPO}@${COMMIT}${DIRTY:+ (with uncommitted changes)}
release=none
EOF
    echo "==> Done (unreleased build). Re-vendor from a release before merging:"
    echo "    scripts/sync-dither-xcframework.sh <version>"
    ;;

  -*)
    usage
    ;;

  *)
    VERSION="${1#v}"
    [ $# -eq 1 ] || usage
    TAG="epaper-dithering-ios-v${VERSION}"
    BASE="https://github.com/${REPO}/releases/download/${TAG}"
    echo "==> Downloading ${TAG}"
    curl -fsSL --retry 3 -o "${WORK}/${ASSET}" "${BASE}/${ASSET}" || {
      echo "error: could not download ${BASE}/${ASSET} — does release ${TAG} exist?" >&2; exit 1; }
    curl -fsSL --retry 3 -o "${WORK}/${ASSET}.checksum" "${BASE}/${ASSET}.checksum" || {
      echo "error: release ${TAG} has no ${ASSET}.checksum" >&2; exit 1; }

    PUBLISHED="$(tr -d '[:space:]' < "${WORK}/${ASSET}.checksum")"
    # Run from WORK: compute-checksum leaves a .build/ directory in the current directory.
    ACTUAL="$(cd "${WORK}" && swift package compute-checksum "${ASSET}")"
    [ "${PUBLISHED}" = "${ACTUAL}" ] || {
      echo "error: checksum mismatch for ${ASSET}: published ${PUBLISHED}, got ${ACTUAL}" >&2; exit 1; }
    echo "==> Checksum OK (${ACTUAL})"

    ditto -x -k "${WORK}/${ASSET}" "${WORK}/unzipped"
    verify_xcframework "${WORK}/unzipped/${XCF_NAME}"
    install_xcframework "${WORK}/unzipped/${XCF_NAME}"
    cat > "${RECORD}" <<EOF
# Written by scripts/sync-dither-xcframework.sh — do not edit by hand.
source=https://github.com/${REPO}/releases/tag/${TAG}
release=${VERSION}
checksum=${ACTUAL}
EOF
    echo "==> Done: vendored epaper-dithering-ios ${VERSION}."
    ;;
esac

echo "    Run the OD AppTests (RustDitherParityTests must stay green)."
