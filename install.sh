#!/bin/zsh
# Build, sign with a stable identity, replace the binary through a fresh inode, reload the agent.
# Any failure leaves the previously installed binary in place.
set -euo pipefail
cd "$(dirname "$0")"
BIN="$HOME/.local/bin/livery"
IDENT="com.shuiandy.livery"

# Piping into grep would hide the compiler's exit status behind grep's, so build first and only then report.
if ! BUILD=$(swift build -c release --product livery 2>&1); then
  echo "build failed:" >&2
  grep -E 'error:' <<<"$BUILD" | head -20 >&2 || echo "$BUILD" | tail -20 >&2
  exit 1
fi
grep -E 'Compiling|Build complete' <<<"$BUILD" | tail -1
[ -x .build/release/livery ] || { echo "build produced no binary" >&2; exit 1; }

# A stable certificate keeps the TCC "App Management" grant across rebuilds. Ad-hoc loses it on every build, so it is
# opt-in rather than a silent fallback.
SIGNER=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')
[ -n "$SIGNER" ] || SIGNER=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development/{print $2; exit}')
if [ -z "$SIGNER" ]; then
  if [ "${LIVERY_ALLOW_ADHOC:-0}" = "1" ]; then
    SIGNER="-"
    echo "warning: no certificate found; signing ad-hoc, App Management must be re-granted after every build" >&2
  else
    echo "no Developer ID or Apple Development certificate in the keychain." >&2
    echo "Install one, or re-run with LIVERY_ALLOW_ADHOC=1 to sign ad-hoc." >&2
    exit 1
  fi
fi
codesign --force --options runtime --identifier "$IDENT" --sign "$SIGNER" .build/release/livery
codesign --verify --strict .build/release/livery
echo "signed with: $SIGNER"

# Never overwrite a running Mach-O in place: the kernel keeps the old cdhash on the vnode and kills every new exec.
# Stage beside the target and swap, keeping the old binary until the new one verifies.
mkdir -p "$(dirname "$BIN")"
STAGE="$BIN.incoming.$$"
BACKUP="$BIN.previous"
cp .build/release/livery "$STAGE"
if ! codesign --verify --strict "$STAGE" || ! "$STAGE" --version >/dev/null 2>&1; then
  rm -f "$STAGE"
  echo "the new binary did not verify; left the installed copy untouched" >&2
  exit 1
fi
[ -f "$BIN" ] && mv -f "$BIN" "$BACKUP"
mv -f "$STAGE" "$BIN"

# The old binary stays until the agent is seen running on the new one; if it is not, the old one goes back.
PLIST="$HOME/Library/LaunchAgents/$IDENT.plist"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/$IDENT" 2>/dev/null || true
  sleep 1
  agent_running() { launchctl print "gui/$(id -u)/$IDENT" 2>/dev/null | grep -q 'state = running'; }
  launchctl bootstrap "gui/$(id -u)" "$PLIST" || true
  # launchd spawns the job a moment after bootstrap returns; give it a few seconds before calling it a failure.
  for _ in $(seq 1 10); do agent_running && break; sleep 0.5; done
  if ! agent_running; then
    echo "the agent did not come up on the new binary; restoring the previous one" >&2
    [ -f "$BACKUP" ] && mv -f "$BACKUP" "$BIN"
    launchctl bootout "gui/$(id -u)/$IDENT" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" || true
    exit 1
  fi
  "$BIN" agent status
else
  echo "agent not installed; run: $BIN agent install"
fi
rm -f "$BACKUP"
