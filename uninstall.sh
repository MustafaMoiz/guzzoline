#!/bin/sh
# Removes Guzzoline from this Mac: the app and its login item; the lid-shut helper, if you turned
# it on (macOS asks for your password for that part); the permissions you gave it; its settings,
# saved numbers and log; and the signing certificate install.sh made. Claude, Claude Code and
# your sessions are left alone. --dry-run lists what it would do, and does nothing.
set -e
APP="$HOME/Applications/Guzzoline.app"
NAME="Guzzoline Local Signing"

DRY=
[ "$1" = "--dry-run" ] && DRY=1
run() {
  if [ -n "$DRY" ]; then
    echo "would run: $*"
  else
    "$@" || true
  fi
}

if [ -x "$APP/Contents/MacOS/Guzzoline" ]; then
  run "$APP/Contents/MacOS/Guzzoline" --forget-login # stops opening at login
fi
run pkill -x Guzzoline
run rm -rf "$APP"

if [ -e /Library/LaunchDaemons/app.guzzoline.awake.plist ] || [ -e /Library/PrivilegedHelperTools/app.guzzoline.awake ]; then
  echo "Removing the lid-shut helper, which needs your password."
  run sudo launchctl bootout system/app.guzzoline.awake
  run sudo rm -f /Library/LaunchDaemons/app.guzzoline.awake.plist /Library/PrivilegedHelperTools/app.guzzoline.awake
  run sudo pmset -a disablesleep 0
fi
if [ -d "/Library/Application Support/Guzzoline" ]; then
  run sudo rm -rf "/Library/Application Support/Guzzoline"
fi

# As you, never as root: a helper from before kept its request in /Users/Shared.
run rm -rf /Users/Shared/Guzzoline "$HOME/Library/Application Support/Guzzoline" "$HOME/Library/Logs/Guzzoline.log" "$HOME/Library/Logs/Guzzoline.old.log"
run defaults delete app.guzzoline
run tccutil reset All app.guzzoline
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  run security delete-identity -c "$NAME"
fi

[ -n "$DRY" ] && echo "(dry run: nothing was removed)" || echo "Guzzoline is gone."
