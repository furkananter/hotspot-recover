#!/bin/bash
# Build, install to ~/.local/bin and start as a launchd user agent.
# Any arguments (e.g. --device "My iPhone" --always) are passed to hotspot-recover.
set -euo pipefail

LABEL="com.github.hotspot-recover"
BIN="$HOME/.local/bin/hotspot-recover"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/hotspot-recover.log"
cd "$(dirname "$0")"

swift build -c release
mkdir -p "$(dirname "$BIN")" "$(dirname "$PLIST")" "$(dirname "$LOG")"
cp .build/release/hotspot-recover "$BIN"
# The log names your phone; keep it private to your user.
touch "$LOG"
chmod 600 "$LOG"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }
ARGS="        <string>$(xml_escape "$BIN")</string>"
for a in "$@"; do
    ARGS+=$'\n'"        <string>$(xml_escape "$a")</string>"
done

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
$ARGS
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed. Log: $LOG"
