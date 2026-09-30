#!/usr/bin/env bash
#
# Applies the patches in this directory to the pinned dependencies.
#
# Alire keeps pinned dependencies under alire/cache/pins/, which is
# gitignored, so changes there do not survive a fresh checkout. Run this
# after cloning, and after anything that re-fetches the pins.
#
# The device and the simulator each get their own checkout of the Tresses
# pin, and common/ is shared between them, so both need the same patches or
# the simulator will not build.
#
# Safe to run more than once, already-applied patches are skipped.

set -u

here="$(cd "$(dirname "$0")" && pwd)"
sdk="$here/../device/alire/cache/pins/noise_nugget_sdk"

tresses_pins=()
for d in "$here/../device/alire/cache/pins/tresses" \
         "$here/../simulator/alire/cache/pins/tresses"; do
    [ -d "$d" ] && tresses_pins+=("$d")
done

if [ ! -d "$sdk" ] || [ ${#tresses_pins[@]} -eq 0 ]; then
    echo "Pins not found. Build once first so Alire fetches the pins, then"
    echo "run this again."
    exit 1
fi

status=0

apply () {
    local patch="$1" target="$2" name label
    name="$(basename "$patch")"
    label="$name ($(basename "$(dirname "$(dirname "$(dirname "$(dirname "$target")")")")"))"

    if git -C "$target" apply --reverse --check "$patch" 2>/dev/null; then
        echo "already applied: $label"
    elif git -C "$target" apply "$patch" 2>/dev/null; then
        echo "applied:         $label"
    else
        echo "FAILED:          $label"
        status=1
    fi
}

apply "$here/noise_nugget_sdk-codec-clock-from-bclk.patch" "$sdk"

for tresses in "${tresses_pins[@]}"; do
    apply "$here/tresses-buzz-zero-detune-cancellation.patch" "$tresses"
    apply "$here/tresses-glide-and-smoothing.patch" "$tresses"
    apply "$here/tresses-live-pitch-bend.patch" "$tresses"
    apply "$here/tresses-pitched-hats.patch" "$tresses"
done

exit $status
