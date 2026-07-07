#!/bin/zsh
set -euo pipefail

TARGET_USER="${1:-}"
if [[ -z "$TARGET_USER" ]]; then
  TARGET_USER="${SUDO_USER:-}"
fi
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  TARGET_USER="$(stat -f '%Su' /dev/console)"
fi
if [[ ! "$TARGET_USER" =~ '^[A-Za-z0-9._-]+$' ]]; then
  echo "Refusing unsafe username: $TARGET_USER" >&2
  exit 1
fi
if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
  echo "User does not exist: $TARGET_USER" >&2
  exit 1
fi

SUDOERS_DIR="/private/etc/sudoers.d"
SUDOERS_FILE="$SUDOERS_DIR/codex-menubar-pmset"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

cat > "$TMP_FILE" <<EOF
# Allows the Codex menu-bar dashboard to toggle closed-lid awake mode without
# prompting for a password. Scope is limited to these exact pmset commands.
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
EOF

chmod 0440 "$TMP_FILE"
/usr/sbin/visudo -cf "$TMP_FILE" >/dev/null
mkdir -p "$SUDOERS_DIR"
install -o root -g wheel -m 0440 "$TMP_FILE" "$SUDOERS_FILE"
/usr/sbin/visudo -cf /private/etc/sudoers >/dev/null

echo "Installed $SUDOERS_FILE for $TARGET_USER"
