#!/bin/sh
# Copies the built app to ~/Applications and starts it from there: that copy is the one that
# opens at login, so rebuilding in build/ doesn't disturb it. Arguments go to the app, e.g.
# --open-at-login to make it a login item.
set -e
cd "$(dirname "$0")/.."
mkdir -p ~/Applications
pkill -x Barometer 2>/dev/null || true
rm -rf ~/Applications/Barometer.app
cp -R build/Barometer.app ~/Applications/
open ~/Applications/Barometer.app --args "$@"
echo "Installed ~/Applications/Barometer.app"
