#!/bin/bash
# Builds the Galgal runtime (iOS-arm64 framework + macOS GalgalInterface plugin) and stages a
# shallow framework with the plugin embedded at the path the Ophanim app build expects.
# This replaces `carthage build` + the Galgal.xcframework. The app's "Copy" build phase then
# vtool-retags it to Mac Catalyst and deep-rebundles it into the .app.
set -euo pipefail

# Put Apple's toolchain + /usr/bin ahead of any shadowing toolchain on PATH (e.g. Anaconda's
# cctools-port vtool/strip/ld/nm/lipo, which segfault or misbehave on our Mach-O outputs).
export PATH="$(dirname "$(xcrun --find clang)"):/usr/bin:/bin:$PATH"
cd "$(dirname "$0")"                      # .../Ophanim/Galgal
APP_ROOT="$(cd .. && pwd)"                # .../Ophanim
STAGE="$APP_ROOT/Carthage/Build/Galgal.xcframework/ios-arm64"
DD="$HOME/Library/Developer/Xcode/DerivedData"

echo "▸ Building Galgal.framework (iOS device, arm64)…"
# xcodebuild output goes to a log, not /dev/null: a swallowed log turned a
# one-line clang diagnostic into a blind red build (InspectorWeb CompileC).
# Quiet on success (tail only), full log on failure.
FW_LOG="$APP_ROOT/Carthage/Build/galgal-fw.log"
mkdir -p "$APP_ROOT/Carthage/Build"
# -U lets the boringssl SSL_read/SSL_write interpose symbols be resolved at load (libboringssl
# is not a linkable library); they bind inside the hosted app.
xcodebuild -project Galgal.xcodeproj -scheme GalgalFW -configuration Release \
  -destination 'generic/platform=iOS' SUPPORTS_MACCATALYST=NO \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  OTHER_LDFLAGS='$(inherited) -Wl,-U,_SSL_read -Wl,-U,_SSL_write' build >"$FW_LOG" 2>&1 || {
  echo "error: GalgalFW build failed — last 60 log lines:" >&2
  tail -60 "$FW_LOG" >&2
  exit 1
}

echo "▸ Building GalgalInterface.bundle (macOS)…"
PLUGIN_LOG="$APP_ROOT/Carthage/Build/galgal-plugin.log"
xcodebuild -project Galgal.xcodeproj -scheme GalgalInterface -configuration Release \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >"$PLUGIN_LOG" 2>&1 || {
  echo "error: GalgalInterface build failed — last 60 log lines:" >&2
  tail -60 "$PLUGIN_LOG" >&2
  exit 1
}

FW_SRC="$(find "$DD"/Galgal-*/Build/Products/Release-iphoneos -maxdepth 1 -name Galgal.framework 2>/dev/null | head -1)"
PLUGIN_SRC="$(find "$DD"/Galgal-*/Build/Products/Release -maxdepth 1 -name GalgalInterface.bundle 2>/dev/null | head -1)"
[ -d "$FW_SRC" ] && [ -d "$PLUGIN_SRC" ] || { echo "error: missing build products" >&2; exit 1; }

echo "▸ Staging shallow framework + plugin at $STAGE …"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$FW_SRC" "$STAGE/Galgal.framework"
mkdir -p "$STAGE/Galgal.framework/PlugIns"
rm -rf "$STAGE/Galgal.framework/PlugIns/GalgalInterface.bundle"
cp -R "$PLUGIN_SRC" "$STAGE/Galgal.framework/PlugIns/GalgalInterface.bundle"

echo "✓ Staged → $STAGE/Galgal.framework (iOS-arm64; app build retags to maccatalyst)"

# Build + stage the sibling-injection agent dylib alongside the framework (same $STAGE dir).
# CWD is the Galgal dir here (cd'd above), so invoke the sibling script by its plain name - deriving
# it from $0 again would double the "Galgal/" prefix and miss the file.
bash build-agent.sh
