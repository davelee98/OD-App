#!/bin/sh
set -eu

EXPECTED="91c44d855f0245a5960e3e828399a9dfb5d0417f1160a8207a2bf4f7c46f13ef"
ACTUAL="$(shasum -a 256 Resources/ble-common.js | awk '{print $1}')"

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "ble-common.js integrity failure: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi

echo "ble-common.js verified: $ACTUAL"
