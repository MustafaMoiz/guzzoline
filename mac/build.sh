#!/bin/sh
# Builds build/Guzzoline.app: the themes (built with Vite) inside the Swift app that shows them
# on the Touch Bar. Universal, for Apple silicon and Intel Touch Bar Macs.
set -e
cd "$(dirname "$0")/.."

npm run build --silent

APP=build/Guzzoline.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/fonts"
cp mac/Info.plist "$APP/Contents/Info.plist"
cp -R dist "$APP/Contents/Resources/web"
# The helper that keeps the Mac awake with the lid shut, installed from here when asked.
cp -R mac/awake "$APP/Contents/Resources/awake"
# The native themes' fonts, the same files the web themes use.
for font in barlow-condensed/files/barlow-condensed-latin-500-normal barlow-condensed/files/barlow-condensed-latin-600-normal \
            ibm-plex-mono/files/ibm-plex-mono-latin-300-normal ibm-plex-mono/files/ibm-plex-mono-latin-400-normal \
            ibm-plex-mono/files/ibm-plex-mono-latin-500-normal; do
  cp "node_modules/@fontsource/$font.woff" "$APP/Contents/Resources/fonts/"
done

# The command line tools no longer carry Intel copies of Swift's back-deployment libraries,
# which this app doesn't use, so it doesn't link them.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12" -runtime-compatibility-version none \
    mac/*.swift -framework AppKit -framework WebKit -framework Metal -framework IOKit -o "build/Guzzoline-$arch"
done
lipo -create build/Guzzoline-arm64 build/Guzzoline-x86_64 -output "$APP/Contents/MacOS/Guzzoline"
rm build/Guzzoline-arm64 build/Guzzoline-x86_64

codesign --force --sign - "$APP"
echo "Built $APP"
