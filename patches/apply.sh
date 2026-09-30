#!/usr/bin/env bash
#
# Applies the patches in this directory to the pinned dependencies.
#
# Alire keeps pinned dependencies under device/alire/cache/pins/, which is
# gitignored, so changes there do not survive a fresh checkout. Run this
# after cloning, and after anything that re-fetches the pins.
#
# Safe to run more than once, already-applied patches are skipped.

set -u

here="$(cd "$(dirname "$0")" && pwd)"
sdk="$here/../device/alire/cache/pins/noise_nugget_sdk"

if [ ! -d "$sdk" ]; then
    echo "noise_nugget_sdk pin not found. Build once first so Alire fetches"
    echo "the pins, then run this again."
    exit 1
fi

status=0

apply () {
    local patch="$1" target="$2" name
    name="$(basename "$patch")"

    if git -C "$target" apply --reverse --check "$patch" 2>/dev/null; then
        echo "already applied: $name"
    elif git -C "$target" apply "$patch" 2>/dev/null; then
        echo "applied:         $name"
    else
        echo "FAILED:          $name"
        status=1
    fi
}

apply "$here/noise_nugget_sdk-codec-clock-from-bclk.patch" "$sdk"

exit $status
