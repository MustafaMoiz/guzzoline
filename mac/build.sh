#!/bin/sh
# Builds build/Guzzoline.app with Apple's command line tools alone, for this Mac's chip, or for
# both Apple silicon and Intel with --universal.
set -e
cd "$(dirname "$0")/.."

APP=build/Guzzoline.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp mac/Info.plist "$APP/Contents/Info.plist"
# The fonts the themes are set in.
cp -R mac/fonts "$APP/Contents/Resources/fonts"

ARCHS=$(uname -m)
[ "$1" = "--universal" ] && ARCHS="arm64 x86_64"
for arch in $ARCHS; do
  # The command line tools no longer carry Intel copies of Swift's back-deployment libraries,
  # which this app doesn't use, so it doesn't link them.
  swiftc -O -swift-version 5 -target "$arch-apple-macos12" -runtime-compatibility-version none \
    mac/*.swift -framework AppKit -framework Metal -framework IOKit \
    -framework AVFoundation -framework Speech -framework ApplicationServices -o "build/Guzzoline-$arch"
done
lipo -create build/Guzzoline-* -output "$APP/Contents/MacOS/Guzzoline"
rm build/Guzzoline-*

# Signed with "Guzzoline Local Signing" when this Mac has it (mac/signing.sh makes it), so macOS
# keeps the app's permissions from one build to the next; otherwise ad hoc, and each build has to
# be allowed again.
IDENTITY=-
if security find-certificate -c "Guzzoline Local Signing" >/dev/null 2>&1; then
  IDENTITY="Guzzoline Local Signing"
else
  echo "Signed ad hoc; run mac/signing.sh once so macOS keeps Guzzoline's permissions across builds"
fi
# Quiet unless it fails (re-signing the linker's own signature always says so).
SIGNED=$(codesign --force --sign "$IDENTITY" "$APP" 2>&1) || { echo "$SIGNED" >&2; exit 1; }
echo "Built $APP"
