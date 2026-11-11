#!/bin/sh
# Builds ~/Applications/AtomHealth.app and installs a launchd agent (auto-start, restart on crash).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$(readlink -f "$ROOT/.venv/bin/python")"
APP="$HOME/Applications/AtomHealth.app"
LABEL=local.atomhealth.server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/ops/Info.plist" "$APP/Contents/Info.plist"
clang -O2 -DPY_PATH="\"$ROOT/.venv/bin/python\"" -DPROJECT_DIR="\"$ROOT\"" \
  -o "$APP/Contents/MacOS/AtomHealth" "$ROOT/ops/launcher.c"
codesign --force --deep -s - "$APP"
cat > "$PLIST" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/AtomHealth</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
<key>StandardOutPath</key><string>$ROOT/data/server.log</string>
<key>StandardErrorPath</key><string>$ROOT/data/server.log</string>
</dict></plist>
P
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $APP  (logs: $ROOT/data/server.log)"
