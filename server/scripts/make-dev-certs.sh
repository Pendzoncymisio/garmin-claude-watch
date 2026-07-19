#!/usr/bin/env bash
# Local HTTPS for simulator development.
#
# Connect IQ refuses plain http with SECURE_CONNECTION_REQUIRED (-1001) — in the
# simulator as well as on the watch — so there is no plaintext dev path. This
# mints a throwaway CA and a server certificate for 127.0.0.1, then builds a CA
# bundle that is the system store *plus* that CA.
#
# Nothing is installed system-wide and no sudo is needed: the simulator picks the
# bundle up through SSL_CERT_FILE (see `make sim`). Dev only — these certs are
# gitignored and must never be used for anything reachable off this machine.
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs"
DAYS=825
SYSTEM_CA=/etc/ssl/certs/ca-certificates.crt

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

echo "==> CA"
openssl genrsa -out ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS" -out ca.pem \
    -subj "/CN=garminApp dev CA" 2>/dev/null

echo "==> server certificate for 127.0.0.1"
openssl genrsa -out server.key 4096 2>/dev/null
openssl req -new -key server.key -out server.csr -subj "/CN=127.0.0.1" 2>/dev/null

# The simulator does not route to loopback — a request to 127.0.0.1 never opens
# a socket at all — so the certificate has to cover this host's LAN address and
# the server has to bind to it.
LAN_IP="$(ip -4 addr show scope global | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
echo "==> LAN address: ${LAN_IP:-none found}"

cat > server.ext <<EOF
authorityKeyIdentifier = keyid,issuer
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]
IP.1  = 127.0.0.1
${LAN_IP:+IP.2  = $LAN_IP}
DNS.1 = localhost
EOF

openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
    -out server.crt -days "$DAYS" -sha256 -extfile server.ext 2>/dev/null

echo "==> CA bundle (system + dev CA)"
# Keep the system roots so the simulator can still reach real hosts while this
# bundle is active.
cat "$SYSTEM_CA" ca.pem > bundle.pem

rm -f server.csr server.ext ca.srl
echo "done: $CERT_DIR"
