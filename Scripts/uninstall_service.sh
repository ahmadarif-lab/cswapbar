#!/usr/bin/env bash
set -euo pipefail

LABEL="dev.ahmadarif.cswap-makeover"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "Uninstalled: $LABEL"
else
    echo "Not installed."
fi
