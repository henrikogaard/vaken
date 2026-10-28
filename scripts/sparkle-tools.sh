#!/bin/sh
# Fetch the pinned official release tooling. No keys are generated or read.
set -eu
cd "$(dirname "$0")/.."
ROOT=build/sparkle-tools/2.10.1
ARCHIVE=build/sparkle-tools/Sparkle-2.10.1.tar.xz
mkdir -p "$ROOT"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --proto '=https' --tlsv1.2 \
        https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz \
        --output "$ARCHIVE"
fi
printf '%s  %s\n' 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27 "$ARCHIVE" | shasum -a 256 -c - >&2
tar -xf "$ARCHIVE" -C "$ROOT"
printf '%s/%s/bin\n' "$PWD" "$ROOT"
