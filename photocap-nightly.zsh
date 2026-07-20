#!/bin/zsh
# photocap-nightly — prune rebuildable Photos caches so they can never silently
# re-bloat. Intended to be run from a launchd agent (see com.photocap.nightly.plist).
#
# Paths are resolved relative to this script's own location so the project can
# live anywhere (no hardcoded user paths).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/.build/release/photocap"
LOG="/tmp/photocap-nightly.log"

# Default to the user's Pictures library; override with PHOTOCAP_LIBRARY if you
# keep your library elsewhere (e.g. on a capped APFS volume).
LIB="${PHOTOCAP_LIBRARY:-$HOME/Pictures/Photos Library.photoslibrary}"

echo "$(date) — photocap nightly run" >> "$LOG"
"$BIN" prune --target database/search/Spotlight --library "$LIB" --force >> "$LOG" 2>&1
"$BIN" prune --target resources/derivatives --library "$LIB" --force >> "$LOG" 2>&1
