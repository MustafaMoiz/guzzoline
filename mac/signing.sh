#!/bin/sh
# Creates "Guzzoline Local Signing", a code-signing certificate for this Mac only, in your login
# keychain, which mac/build.sh then signs with. Builds signed with it keep one identity, so macOS
# keeps their permissions (Accessibility, the microphone, keychain access) from one build to the
# next; ad hoc builds each look like a new app to it. Delete it in Keychain Access whenever you
# like, and builds go back to ad hoc.
set -e
NAME="Guzzoline Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "$NAME is already in your keychain"
  exit 0
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/certificate.cnf" <<EOF
[req]
distinguished_name = name
prompt = no
x509_extensions = signing
[name]
CN = $NAME
[signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
# macOS's own LibreSSL, whose PKCS #12 files the keychain reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/certificate.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" 2>/dev/null
PASSWORD=$(/usr/bin/openssl rand -hex 16) # protects the bundle below for the moment it exists
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/certificate.pem" -name "$NAME" \
  -passout "pass:$PASSWORD" -out "$WORK/identity.p12"
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASSWORD" -T /usr/bin/codesign
echo "Created $NAME in your login keychain"
