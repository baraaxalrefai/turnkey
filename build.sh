#!/bin/bash
# Builds "Turnkey.app", checks it contains no networking code, signs it locally and (with --install)
# copies it to ~/Applications and launches it.
#
#   ./build.sh            build into ./build/
#   ./build.sh --install  build, install to ~/Applications, (re)launch
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Turnkey"
EXEC="Turnkey"
BUNDLE_ID="io.github.baraaxalrefai.turnkey"
OUT="build/${APP_NAME}.app"
INSTALL_DIR="$HOME/Applications"

# 1. Offline guarantee: refuse to build if any networking API shows up in the sources.
NET_PATTERN='URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWBrowser|NWPathMonitor|import Network|CFSocket|CFStream|CFReadStream|CFWriteStream|WKWebView|SCNetworkReachability|getaddrinfo|socket\(|SFSafariViewController|URLSessionWebSocketTask'
if grep -rnE "$NET_PATTERN" Sources; then
  echo "error: networking API found in Sources/ — Turnkey must stay offline." >&2
  exit 1
fi

# 2. Tests + release build.
swift test 2>&1 | tail -3
swift build -c release 2>&1 | tail -2
BIN="$(swift build -c release --show-bin-path)/${EXEC}"

# 3. App bundle.
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${EXEC}"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
if [[ ! -f build/AppIcon.icns ]]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

# 4. The binary must not link any networking framework directly.
if otool -L "$OUT/Contents/MacOS/${EXEC}" | grep -qE 'Network\.framework|CFNetwork|WebKit'; then
  echo "error: binary links a networking framework." >&2
  exit 1
fi

# 5. Local ad-hoc signature with a stable designated requirement, so the Camera and Accessibility
#    permissions you grant keep working after rebuilds.
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$OUT"
codesign --verify --strict "$OUT"
echo "Built: $OUT"

if [[ "${1:-}" == "--install" ]]; then
  if pgrep -x "$EXEC" >/dev/null; then
    pkill -x "$EXEC" || true
    sleep 1
  fi
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/${APP_NAME}.app"
  ditto "$OUT" "$INSTALL_DIR/${APP_NAME}.app"
  echo "Installed: $INSTALL_DIR/${APP_NAME}.app"
  open "$INSTALL_DIR/${APP_NAME}.app"
fi
