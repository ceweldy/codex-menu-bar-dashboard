#!/bin/zsh
set -euo pipefail

SUDOERS_FILE="/private/etc/sudoers.d/codex-menubar-pmset"

rm -f "$SUDOERS_FILE"
/usr/sbin/visudo -cf /private/etc/sudoers >/dev/null

echo "Removed $SUDOERS_FILE"
