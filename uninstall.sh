#!/bin/bash
set -euo pipefail

LABEL="com.github.hotspot-recover"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/hotspot-recover"
echo "Uninstalled."
