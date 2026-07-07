#!/bin/zsh
set -euo pipefail

LAUNCH_AGENT_LABEL="${CODEX_MENU_BAR_LAUNCH_AGENT_LABEL:-io.github.codex-menu-bar.dashboard}"
PLIST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
UID_VALUE="$(id -u)"

launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Codex menu bar dashboard launch agent removed."
