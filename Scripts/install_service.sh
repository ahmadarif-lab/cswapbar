#!/usr/bin/env bash
# Registers CSwapBar as a launchd LaunchAgent: starts at login, restarts on
# crash. Mirrors `cswap menubar --install-service`.
#
# Works both from a source checkout and from inside the installed app bundle
# (build_app.sh copies this script into CSwapBar.app/Contents/Resources).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="dev.ahmadarif.cswapbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

find_app_binary() {
    # Running from inside CSwapBar.app/Contents/Resources
    local bundled="${SCRIPT_DIR%/Contents/Resources}/Contents/MacOS/CSwapBar"
    if [ "$bundled" != "$SCRIPT_DIR/Contents/MacOS/CSwapBar" ] && [ -x "$bundled" ]; then
        echo "$bundled"
        return
    fi
    # Installed via Homebrew cask
    if [ -x "/Applications/CSwapBar.app/Contents/MacOS/CSwapBar" ]; then
        echo "/Applications/CSwapBar.app/Contents/MacOS/CSwapBar"
        return
    fi
    # Local build from a source checkout
    local built="$(cd "$SCRIPT_DIR/.." && pwd)/dist/CSwapBar.app/Contents/MacOS/CSwapBar"
    if [ -x "$built" ]; then
        echo "$built"
        return
    fi
    return 1
}

if ! APP_BIN="$(find_app_binary)"; then
    echo "CSwapBar.app not found. Install the cask, or run Scripts/build_app.sh first." >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/$LABEL.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/$LABEL.err</string>
</dict>
</plist>
PLIST_EOF

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST"

echo "Installed and started: $LABEL"
echo "  app:   $APP_BIN"
echo "  plist: $PLIST"
echo "  logs:  $HOME/Library/Logs/$LABEL.log"
