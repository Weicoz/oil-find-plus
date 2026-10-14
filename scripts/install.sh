#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$PROJECT_DIR/scripts/build-app.sh"

for application in 'Sift:com.oiloil.sift' 'OilFind:com.oiloil.find'; do
    process_name="${application%%:*}"
    bundle_id="${application#*:}"
    if pgrep -x "$process_name" >/dev/null; then
        osascript -e "quit app id \"$bundle_id\"" &
        QUIT_REQUEST_PID=$!
        for ((attempt = 0; attempt < 50; attempt++)); do
            if ! pgrep -x "$process_name" >/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$QUIT_REQUEST_PID" 2>/dev/null; then kill "$QUIT_REQUEST_PID" 2>/dev/null || true; fi
        wait "$QUIT_REQUEST_PID" 2>/dev/null || true
        if pgrep -x "$process_name" >/dev/null; then
            printf '%s did not quit within 5 seconds.\n' "$process_name" >&2
            exit 1
        fi
    fi
done

rm -rf "/Applications/Sift.app" "$HOME/Library/Application Support/Sift" "$HOME/Library/Caches/Sift"
if defaults read com.oiloil.sift >/dev/null 2>&1; then
    defaults delete com.oiloil.sift
fi
ditto "$PROJECT_DIR/build/Oil Find Plus.app" "/Applications/Oil Find Plus.app"
for ((attempt = 1; attempt <= 5; attempt++)); do
    if open "/Applications/Oil Find Plus.app"; then exit 0; fi
    if ((attempt < 5)); then sleep 1; fi
done
printf '%s\n' 'Oil Find Plus could not be opened after 5 attempts.' >&2
exit 1
