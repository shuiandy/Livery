#!/bin/zsh
# Build and sign the app (build-app.sh), install the command line tool, replace ~/Applications/Livery.app, relaunch.
set -euo pipefail
cd "$(dirname "$0")"
IDENT="com.shuiandy.Livery"
APP_NAME="Livery"
OUT="build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"

./build-app.sh

# The app's background-agent switch prefers this binary, so a GUI-only install would leave the two out of step.
./install.sh

# Quit the running copy, replace the bundle through a fresh directory, relaunch. Never overwrite a running Mach-O in
# place. The old bundle is kept until the new one is in position, so a failed copy is recoverable.
osascript -e "tell application id \"$IDENT\" to quit" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 1; done
pkill -x "$APP_NAME" 2>/dev/null || true
mkdir -p "$HOME/Applications"
BACKUP="$DEST.previous"
rm -rf "$BACKUP"
[ -d "$DEST" ] && mv "$DEST" "$BACKUP"
restore_previous() {
  echo "$1; restoring the previous bundle" >&2
  rm -rf "$DEST"
  [ -d "$BACKUP" ] && mv "$BACKUP" "$DEST" && env -u TZ open "$DEST" || true
  exit 1
}
cp -R "$OUT" "$DEST" || restore_previous "install failed"
# The backup goes only once the new app is seen running: a bundle that will not launch is not an install.
env -u TZ open "$DEST" || restore_previous "the new app did not open"
for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null && break; sleep 0.5; done
pgrep -x "$APP_NAME" >/dev/null || restore_previous "the new app did not start within 10 seconds"
rm -rf "$BACKUP"
echo "installed $DEST"
