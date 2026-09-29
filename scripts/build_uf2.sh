#!/bin/sh
# Build the PGB-1 device firmware and drop a flashable .uf2 into builds/.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.alire/bin:$PATH"

cd "$REPO_ROOT/device"
# --release is mandatory: a debug build is too slow for the real-time audio
# path on real hardware and will hang/brick the device.
alr --non-interactive build --release

ELF="$(ls -t bin/*release*.elf | head -n1)"
mkdir -p "$REPO_ROOT/builds"
OUT="$REPO_ROOT/builds/WNM-PGB1-$(date +'%Y%m%d-%H%M').uf2"

picotool uf2 convert "$ELF" "$OUT"
echo "Built: $OUT"
