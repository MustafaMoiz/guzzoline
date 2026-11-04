#!/bin/sh
# Builds Guzzoline on this Mac and installs it in ~/Applications, opening now and at every login.
# Run it again after `git pull` to update. It needs only Apple's free command line tools.
set -e
cd "$(dirname "$0")"

stop() {
  printf '\n%s\n\n' "$*" >&2
  exit 1
}

# The Touch Bar's own server runs only on Macs that have one.
pgrep -x TouchBarServer >/dev/null || stop "This Mac doesn't have a Touch Bar, and Guzzoline lives on the Touch Bar."
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 12 ] || stop "Guzzoline needs macOS 12 or later."

# The command line tools come with git, so most people already have them.
if ! xcrun --find swiftc >/dev/null 2>&1; then
  xcode-select --install 2>/dev/null || true
  stop "Guzzoline is built with Apple's free command line tools. macOS is offering to install them; once they're in, run ./install.sh again."
fi

# A certificate for this Mac alone, so macOS keeps the permissions you give Guzzoline from one
# update to the next. Made once. To build without it, run: GUZZOLINE_AD_HOC=1 ./install.sh
if [ -z "$GUZZOLINE_AD_HOC" ] && ! security find-certificate -c "Guzzoline Local Signing" >/dev/null 2>&1; then
  echo "Making a signing certificate for this Mac, so updates keep Guzzoline's permissions."
  echo "macOS may ask you to let codesign use it: enter your Mac's password and choose Always Allow."
  sh mac/signing.sh
fi

echo "Building Guzzoline (about half a minute)..."
sh mac/build.sh >/dev/null
sh mac/install.sh --open-at-login >/dev/null

cat <<'EOF'

Guzzoline is running: look for Clawd in the menu bar, and click it for the panel.

  - The Touch Bar shows your usage while the Claude app is in front.
  - Touch a Clawd to read its session's title; lift to open it.
  - Hold a Clawd and speak; let go to send. macOS asks for the microphone
    the first time, and for Accessibility the first time you send.

To update later: git pull && ./install.sh
To remove it:    ./uninstall.sh

EOF
