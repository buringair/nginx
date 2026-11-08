#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="$CERT_DIR/ca"
cd "$CERT_DIR"

[[ -r "$CA_DIR/ca.crt" && -r "$CA_DIR/ca.key" ]] || {
  echo "CA certificate and private key must exist in $CA_DIR" >&2
  exit 1
}

openssl x509 -in "$CA_DIR/ca.crt" -noout >/dev/null
openssl pkey -in "$CA_DIR/ca.key" -noout >/dev/null
openssl x509 -in "$CA_DIR/ca.crt" -noout -checkend 0 >/dev/null
openssl x509 -in "$CA_DIR/ca.crt" -noout -text |
  grep -q 'CA:TRUE' || {
    echo "Certificate in $CA_DIR/ca.crt is not a CA certificate" >&2
    exit 1
  }

ca_cert_public_key="$(
  openssl x509 -in "$CA_DIR/ca.crt" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    sha256sum | awk '{print $1}'
)"
ca_private_public_key="$(
  openssl pkey -in "$CA_DIR/ca.key" -pubout -outform DER |
    sha256sum | awk '{print $1}'
)"
[[ "$ca_cert_public_key" == "$ca_private_public_key" ]] || {
  echo "CA certificate and private key in $CA_DIR do not match" >&2
  exit 1
}

rm -f proxy1.key proxy1.csr proxy1.crt proxy2.key proxy2.csr proxy2.crt proxy1-client.key proxy1-client.csr proxy1-client.crt

# Public server certificate for proxy1.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy1.key \
  -out proxy1.csr \
  -subj "/CN=sso-config.lb.abc.cn" \
  -addext "subjectAltName=DNS:sso-config.lb.abc.cn,DNS:sso-logging.lb.abc.cn"

openssl x509 -req -in proxy1.csr \
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
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
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
  -out proxy2.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy2.csr

# Client certificate proxy1 presents to proxy2.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy1-client.key \
  -out proxy1-client.csr \
  -subj "/CN=proxy1-client"

openssl x509 -req -in proxy1-client.csr \
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" -CAcreateserial \
  -out proxy1-client.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy1-client.csr

chmod 600 *.key
chmod 644 *.crt

echo "Generated ABC proxy certificates in $CERT_DIR using the existing CA in $CA_DIR"
