#!/bin/sh
set -eu

EXPECTED="583832deefde7552155d835cf1ec39b1d97f87175a79bb04d2e9e77987f02be2"
ACTUAL="$(shasum -a 256 Resources/ble-common.js | awk '{print $1}')"

if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "ble-common.js integrity failure: expected $EXPECTED, got $ACTUAL" >&2
  exit 1
fi

echo "ble-common.js verified: $ACTUAL"
