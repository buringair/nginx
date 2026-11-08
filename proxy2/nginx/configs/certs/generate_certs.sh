#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")" && pwd)"
CA_DIR="$CERT_DIR/ca"
mkdir -p "$CA_DIR"
cd "$CERT_DIR"

if [[ -f "$CA_DIR/ca.crt" && -f "$CA_DIR/ca.key" ]]; then
  echo "Preserving the existing CA files in $CA_DIR"
elif [[ -e "$CA_DIR/ca.crt" || -e "$CA_DIR/ca.key" || -e "$CA_DIR/ca.srl" ]]; then
  echo "CA directory is incomplete; refusing to replace existing CA files in $CA_DIR" >&2
  exit 1
else
  # Create the CA only for a fresh certificate directory.
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -keyout "$CA_DIR/ca.key" \
    -out "$CA_DIR/ca.crt" \
    -subj "/CN=ABC Internal Root CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash"
  chmod 600 "$CA_DIR/ca.key"
  chmod 644 "$CA_DIR/ca.crt"
fi

ca_public_key="$(openssl x509 -in "$CA_DIR/ca.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d ' ' -f 1)"
ca_private_key="$(openssl pkey -in "$CA_DIR/ca.key" -pubout -outform DER | sha256sum | cut -d ' ' -f 1)"
if [[ "$ca_public_key" != "$ca_private_key" ]]; then
  echo "CA certificate does not match CA private key in $CA_DIR" >&2
  exit 1
fi

rm -f proxy1.key proxy1.csr proxy1.crt proxy2.key proxy2.csr proxy2.crt \
  proxy1-client.key proxy1-client.csr proxy1-client.crt

# Public server certificate for proxy1.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy1.key \
  -out proxy1.csr \
  -subj "/CN=sso-config.lb.abc.cn" \
  -addext "subjectAltName=DNS:sso-config.lb.abc.cn,DNS:sso-logging.lb.abc.cn"

openssl x509 -req -in proxy1.csr \
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -set_serial "0x$(openssl rand -hex 16)" \
  -out proxy1.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy1.csr

# Internal server certificate for proxy2.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy2.key \
  -out proxy2.csr \
  -subj "/CN=cn-sso-config.lb.abc.com" \
  -addext "subjectAltName=DNS:cn-sso-config.lb.abc.com,DNS:cn-sso-logging.lb.abc.com"

openssl x509 -req -in proxy2.csr \
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -set_serial "0x$(openssl rand -hex 16)" \
  -out proxy2.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy2.csr

# Client certificate proxy1 presents to proxy2.
openssl req -new -newkey rsa:2048 -nodes \
  -keyout proxy1-client.key \
  -out proxy1-client.csr \
  -subj "/CN=proxy1-client"

openssl x509 -req -in proxy1-client.csr \
  -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -set_serial "0x$(openssl rand -hex 16)" \
  -out proxy1-client.crt -days 825 -sha256 \
  -copy_extensions copyall
rm -f proxy1-client.csr

chmod 600 *.key
chmod 644 *.crt

echo "Generated ABC proxy certificates in $CERT_DIR; existing CA files were preserved."
