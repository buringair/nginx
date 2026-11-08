#!/usr/bin/env bash
set -Eeuo pipefail

CERT_SOURCE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CERT_TARGET="/etc/nginx/certs"
CERT_FILE="$CERT_TARGET/sso-origin.crt"
KEY_FILE="$CERT_TARGET/sso-origin.key"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0" >&2
    exit 1
fi

for file in "$CERT_SOURCE/ca.crt" "$CERT_SOURCE/ca.key" "$CERT_SOURCE/ca.srl"; do
    if [[ ! -f "$file" ]]; then
        echo "Required CA file is missing: $file" >&2
        exit 1
    fi
done

install -d -o root -g root -m 755 "$CERT_TARGET"
TEMP_DIR="$(mktemp -d "$CERT_TARGET/sso-origin-cert.XXXXXXXX")"
trap 'rm -f "$TEMP_DIR/sso-origin.key" "$TEMP_DIR/sso-origin.csr" "$TEMP_DIR/sso-origin.crt" "$TEMP_DIR/extensions.cnf"; rmdir "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/extensions.cnf" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:sso-config.lb.abc.com,DNS:sso-logging.lb.abc.com
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOF

openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -keyout "$TEMP_DIR/sso-origin.key" \
    -out "$TEMP_DIR/sso-origin.csr" \
    -subj "/CN=sso-config.lb.abc.com" \
    -addext "subjectAltName=DNS:sso-config.lb.abc.com,DNS:sso-logging.lb.abc.com"

openssl x509 -req -in "$TEMP_DIR/sso-origin.csr" \
    -CA "$CERT_SOURCE/ca.crt" \
    -CAkey "$CERT_SOURCE/ca.key" \
    -CAserial "$CERT_SOURCE/ca.srl" \
    -out "$TEMP_DIR/sso-origin.crt" \
    -days 825 -sha256 \
    -extfile "$TEMP_DIR/extensions.cnf"

openssl verify -CAfile "$CERT_SOURCE/ca.crt" -purpose sslserver \
    -verify_hostname sso-config.lb.abc.com "$TEMP_DIR/sso-origin.crt"
openssl verify -CAfile "$CERT_SOURCE/ca.crt" -purpose sslserver \
    -verify_hostname sso-logging.lb.abc.com "$TEMP_DIR/sso-origin.crt"

cert_public_key="$(openssl x509 -in "$TEMP_DIR/sso-origin.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d ' ' -f 1)"
key_public_key="$(openssl pkey -in "$TEMP_DIR/sso-origin.key" -pubout -outform DER | sha256sum | cut -d ' ' -f 1)"
if [[ "$cert_public_key" != "$key_public_key" ]]; then
    echo "Generated origin certificate does not match its key" >&2
    exit 1
fi

install -o root -g root -m 644 "$TEMP_DIR/sso-origin.crt" "$CERT_FILE"
install -o root -g root -m 600 "$TEMP_DIR/sso-origin.key" "$KEY_FILE"
echo "Origin certificate and key installed in $CERT_TARGET"
