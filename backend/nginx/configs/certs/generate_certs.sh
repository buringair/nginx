#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$CERT_DIR"

rm -f ca.key ca.crt ca.srl proxy1.key proxy1.csr proxy1.crt proxy2.key proxy2.csr proxy2.crt proxy1-client.key proxy1-client.csr proxy1-client.crt

# Create a local CA for the proxy1 -> proxy2 mTLS trust boundary.
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout ca.key \
  -out ca.crt \
  -subj "/CN=ABC Internal Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

# Public server certificate for proxy1.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy1.key \
  -out proxy1.csr \
  -subj "/CN=sso-config.lb.abc.cn" \
  -addext "subjectAltName=DNS:sso-config.lb.abc.cn,DNS:sso-logging.lb.abc.cn"

openssl x509 -req -in proxy1.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out proxy1.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy1.csr

# Internal server certificate for proxy2.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy2.key \
  -out proxy2.csr \
  -subj "/CN=cn-sso-config.lb.abc.com" \
  -addext "subjectAltName=DNS:cn-sso-config.lb.abc.com"

openssl x509 -req -in proxy2.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out proxy2.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy2.csr

# Client certificate proxy1 presents to proxy2.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy1-client.key \
  -out proxy1-client.csr \
  -subj "/CN=proxy1-client"

openssl x509 -req -in proxy1-client.csr \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out proxy1-client.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy1-client.csr

chmod 600 *.key
chmod 644 *.crt

echo "Generated ABC proxy certificates in $CERT_DIR"
