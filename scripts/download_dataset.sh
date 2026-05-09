#!/usr/bin/env bash
set -euo pipefail

DATA_DIR=./data
GZ_NAME=NASA_access_log_Jul95.gz
RAW_NAME=NASA_access_log_Jul95
PRIMARY_URL=https://raw.githubusercontent.com/greymd/NASA-HTTP/main/NASA_access_log_Jul95.gz
FALLBACK_URL=ftp://ita.ee.lbl.gov/traces/NASA_access_log_Jul95.gz
EXPECTED_SHA256=199109ed0f273e095da6ccd5fc9dc4cd8bb58daa06d62135e62090fea9d27488

RAW_PATH="$DATA_DIR/$RAW_NAME"
GZ_PATH="$DATA_DIR/$GZ_NAME"

# Idempotent: skip if uncompressed file already present with expected size
if [ -f "$RAW_PATH" ]; then
    size=$(wc -c < "$RAW_PATH")
    if [ "$size" -ge 200000000 ] && [ "$size" -le 220000000 ]; then
        echo "Already downloaded: $RAW_PATH ($size bytes). Skipping."
        exit 0
    fi
fi

# Download .gz if not cached
if [ ! -f "$GZ_PATH" ]; then
    echo "Downloading from primary URL..."
    if ! curl -fL --retry 3 --retry-delay 5 -o "$GZ_PATH" "$PRIMARY_URL"; then
        echo "Primary failed. Trying fallback URL..."
        curl -fL --retry 3 --retry-delay 5 -o "$GZ_PATH" "$FALLBACK_URL"
    fi
fi

# SHA-256 verification
actual_sha=$(sha256sum "$GZ_PATH" | awk '{print $1}')

if [ -z "$EXPECTED_SHA256" ]; then
    echo ""
    echo "========================================================"
    echo "  BOOTSTRAP: SHA-256 hash computed from first download"
    echo "  Paste this value into EXPECTED_SHA256 in this script:"
    echo ""
    echo "  $actual_sha"
    echo "========================================================"
    echo ""
    exit 0
fi

if [ "$actual_sha" != "$EXPECTED_SHA256" ]; then
    echo "SHA-256 mismatch!" >&2
    echo "  expected: $EXPECTED_SHA256" >&2
    echo "  actual:   $actual_sha" >&2
    rm -f "$GZ_PATH"
    exit 1
fi

echo "SHA-256 verified."

# Decompress (keep .gz as download cache)
gunzip -kf "$GZ_PATH"

echo "Size:  $(wc -c < "$RAW_PATH") bytes"
echo "Lines: $(wc -l < "$RAW_PATH")"
