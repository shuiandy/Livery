#!/bin/zsh
# Build the SwiftUI app, its helper and the command line tool, wrap them in build/Livery.app and sign it.
# install-app.sh installs what this produces; release.sh wraps it in a disk image. Nothing here touches ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
IDENT="com.shuiandy.Livery"
HELPER="com.shuiandy.Livery.helper"
CLI="com.shuiandy.livery"
APP_NAME="Livery"
OUT="build/$APP_NAME.app"
VERSION=$(grep -o 'string = "[^"]*"' Sources/LiveryCore/Commands.swift | head -1 | cut -d'"' -f2)

# Piping into grep would hide the compiler's exit status behind grep's, so build first and only then report.
if ! BUILD=$(swift build -c release 2>&1); then
  echo "build failed:" >&2
  grep -E 'error:' <<<"$BUILD" | head -20 >&2 || echo "$BUILD" | tail -20 >&2
  exit 1
fi
grep -E 'Build complete' <<<"$BUILD" | tail -1
for product in LiveryApp LiveryHelper livery; do
  [ -x ".build/release/$product" ] || { echo "build produced no $product" >&2; exit 1; }
done

# A stable certificate keeps the TCC grants (App Management for the helper, Login Items for the daemon) across
# rebuilds. Ad-hoc loses them every time, so it is opt-in rather than a silent fallback.
SIGNER=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/{print $2; exit}')
[ -n "$SIGNER" ] || SIGNER=$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Apple Development/{print $2; exit}')
if [ -z "$SIGNER" ]; then
  if [ "${LIVERY_ALLOW_ADHOC:-0}" = "1" ]; then
    SIGNER="-"
    echo "warning: no certificate found; signing ad-hoc, every TCC grant must be given again" >&2
  else
    echo "no Developer ID or Apple Development certificate in the keychain." >&2
    echo "Install one, or re-run with LIVERY_ALLOW_ADHOC=1 to sign ad-hoc." >&2
    exit 1
  fi
fi
# A trusted timestamp keeps the signature valid after the certificate expires; it needs the network, so releases ask for it.
TIMESTAMP=()
[ "${LIVERY_TIMESTAMP:-0}" = "1" ] && [ "$SIGNER" != "-" ] && TIMESTAMP=(--timestamp)

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Helpers" "$OUT/Contents/Resources" "$OUT/Contents/Library/LaunchDaemons"
cp .build/release/LiveryApp "$OUT/Contents/MacOS/$APP_NAME"
cp .build/release/LiveryHelper "$OUT/Contents/MacOS/LiveryHelper"
# The command line tool rides inside the bundle so the background agent has something to run on a Mac that never ran
# install.sh; the app prefers ~/.local/bin/livery when that exists. It lives in Helpers, not MacOS: on a
# case-insensitive volume "livery" and "Livery" are the same file, and the tool would replace the app.
cp .build/release/livery "$OUT/Contents/Helpers/livery"
cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$OUT/Contents/Resources/"
# SMAppService daemon: launchd runs it as root from inside this bundle, on demand when the mach service is dialled.
cat > "$OUT/Contents/Library/LaunchDaemons/$HELPER.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$HELPER</string>
  <key>BundleProgram</key><string>Contents/MacOS/LiveryHelper</string>
  <key>MachServices</key><dict><key>$HELPER</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key><array><string>$IDENT</string></array>
</dict>
</plist>
PLIST
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$IDENT</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# The application-identifier entitlement gives the daemon an app identity so TCC can grant it App Management. It is
# prefixed with the team that owns the signing certificate, so it is generated here rather than checked in: a fork
# signed with a different certificate gets its own team without editing any source.
HELPER_SIGN_ARGS=()
if [ "$SIGNER" = "-" ]; then
  # No team, so no application-identifier and no XPC gate the helper could bind to: it refuses every caller, and apps
  # owned by root cannot be written on this build. Everything the user owns still works.
  TEAM=""
  echo "warning: ad-hoc build; the privileged helper is inert, root-owned apps cannot be written" >&2
else
  TEAM=$(security find-certificate -c "$SIGNER" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p')
  if [ -z "$TEAM" ]; then
    echo "could not read a team identifier out of '$SIGNER'." >&2
    echo "The privileged helper binds its XPC gate to that team and refuses every caller without one." >&2
    exit 1
  fi
  ENTITLEMENTS="build/Helper.entitlements"
  cat > "$ENTITLEMENTS" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>$TEAM.$HELPER</string>
</dict>
</plist>
ENT
  HELPER_SIGN_ARGS=(--entitlements "$ENTITLEMENTS")
fi

# Nested code first, then the bundle; the identifiers are what the daemon plist, the XPC gate and TCC refer to.
codesign --force --options runtime --identifier "$HELPER" "${HELPER_SIGN_ARGS[@]}" "${TIMESTAMP[@]}" \
  --sign "$SIGNER" "$OUT/Contents/MacOS/LiveryHelper"
codesign --force --options runtime --identifier "$CLI" "${TIMESTAMP[@]}" --sign "$SIGNER" "$OUT/Contents/Helpers/livery"
codesign --force --options runtime --identifier "$IDENT" "${TIMESTAMP[@]}" --sign "$SIGNER" "$OUT"
codesign --verify --deep --strict "$OUT"
printf '%s' "$SIGNER" > build/signer
echo "signed with: $SIGNER${TEAM:+ (team $TEAM)}"
echo "built $OUT ($VERSION)"
