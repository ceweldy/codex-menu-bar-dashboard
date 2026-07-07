#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT_DIR/.build/release/CodexMenuBar"
APP_DIR="$ROOT_DIR/build/CodexMenuBar.app"
APP_BINARY="$APP_DIR/Contents/MacOS/CodexMenuBar"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
BUNDLE_IDENTIFIER="${CODEX_MENU_BAR_BUNDLE_IDENTIFIER:-io.github.codex-menu-bar.dashboard}"
LAUNCH_AGENT_LABEL="${CODEX_MENU_BAR_LAUNCH_AGENT_LABEL:-$BUNDLE_IDENTIFIER}"
PLIST="$HOME/Library/LaunchAgents/$LAUNCH_AGENT_LABEL.plist"
LOG_DIR="$HOME/.codex-menu-bar"
UID_VALUE="$(id -u)"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$HOME/Library/LaunchAgents" "$LOG_DIR"
cp "$BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

/usr/libexec/PlistBuddy -c "Clear dict" "$INFO_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDevelopmentRegion string en" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string CodexMenuBar" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_IDENTIFIER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Codex Dashboard" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 1.0" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :NSHighResolutionCapable bool true" "$INFO_PLIST"

/usr/libexec/PlistBuddy -c "Clear dict" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :Label string $LAUNCH_AGENT_LABEL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments array" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $APP_BINARY" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :RunAtLoad bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :KeepAlive bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LimitLoadToSessionType string Aqua" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :ThrottleInterval integer 10" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :StandardOutPath string $LOG_DIR/codexmenubar.out.log" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :StandardErrorPath string $LOG_DIR/codexmenubar.err.log" "$PLIST"

launchctl bootout "gui/$UID_VALUE" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_VALUE" "$PLIST"
launchctl kickstart -k "gui/$UID_VALUE/$LAUNCH_AGENT_LABEL"

echo "Codex menu bar dashboard installed and started."
