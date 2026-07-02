#!/bin/sh
set -eu

SOURCE="${1:-../opendisplay.org/httpdocs/js/ble-common.js}"
DESTINATION="Resources/ble-common.js"

cp "$SOURCE" "$DESTINATION"
shasum -a 256 "$DESTINATION"
echo "Update EXPECTED in scripts/verify-ble-common.sh after reviewing the upstream change."
