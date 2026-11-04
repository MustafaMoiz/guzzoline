#!/bin/sh
# Copies the built app to ~/Applications and starts it from there: that copy is the one that
# opens at login, so rebuilding in build/ doesn't disturb it. Arguments go to the app, e.g.
# --open-at-login to make it a login item.
set -e
cd "$(dirname "$0")/.."
mkdir -p ~/Applications
pkill -x Guzzoline 2>/dev/null || true
# Opening it again before the old one has quit fails, so wait for it (up to five seconds).
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Guzzoline >/dev/null || break; sleep 0.5; done
rm -rf ~/Applications/Guzzoline.app
cp -R build/Guzzoline.app ~/Applications/
open ~/Applications/Guzzoline.app --args "$@"
echo "Installed ~/Applications/Guzzoline.app"
