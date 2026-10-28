#!/usr/bin/env bash
# Copies UnoWheel's rides, charges and cached board state off a connected iPhone.
# Usage: pull.sh [destination]   (default /tmp/unowheel-pull)
# Set UNOWHEEL_DEVICE to a device name or UDID to pick one phone.
set -euo pipefail

bundle=sh.dunkirk.unowheel
dest=${1:-/tmp/unowheel-pull}

devices=$(xcrun devicectl list devices 2>/dev/null | awk '/available \(paired\)/ && /physical/')
if [[ -n "${UNOWHEEL_DEVICE:-}" ]]; then
    devices=$(grep -F -- "$UNOWHEEL_DEVICE" <<<"$devices" || true)
fi
udid=$(grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' <<<"$devices" | head -1 || true)
if [[ -z "$udid" ]]; then
    echo "No paired iPhone available. Plug it in or join the same network, then check: xcrun devicectl list devices" >&2
    exit 1
fi
echo "Pulling from $(awk '{print $1}' <<<"$devices" | head -1) ($udid) into $dest"

rm -rf "$dest"
mkdir -p "$dest"

# devicectl sometimes drops the connection mid-copy; retry a few times.
copy() {
    local source=$1 target=$2
    for attempt in 1 2 3; do
        if xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer \
            --domain-identifier "$bundle" --source "$source" --destination "$target" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    echo "Couldn't copy $source after 3 tries" >&2
    return 1
}

copy "Library/Application Support" "$dest"
copy "Library/Preferences/$bundle.plist" "$dest/prefs.plist" || true

echo "rides:   $(ls "$dest/rides" 2>/dev/null | wc -l | tr -d ' ')"
echo "charges: $(ls "$dest/charges" 2>/dev/null | wc -l | tr -d ' ')"
