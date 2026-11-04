#!/bin/sh
# Builds build/Barometer.app: the themes (built with Vite) inside the Swift app that shows them
# on the Touch Bar. Universal, for Apple silicon and Intel Touch Bar Macs.
set -e
cd "$(dirname "$0")/.."

npm run build --silent

APP=build/Barometer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp mac/Info.plist "$APP/Contents/Info.plist"
cp -R dist "$APP/Contents/Resources/web"

# The command line tools no longer carry Intel copies of Swift's back-deployment libraries,
# which this app doesn't use, so it doesn't link them.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos12" -runtime-compatibility-version none \
    mac/Barometer.swift -framework AppKit -framework WebKit -o "build/Barometer-$arch"
done
lipo -create build/Barometer-arm64 build/Barometer-x86_64 -output "$APP/Contents/MacOS/Barometer"
rm build/Barometer-arm64 build/Barometer-x86_64

codesign --force --sign - "$APP"
echo "Built $APP"
