#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CERT_SOURCE="$SOURCE_DIR/configs/certs"
CONFIG_SOURCE="$SOURCE_DIR/configs/proxy2.conf"
CONFIG_TARGET="/etc/nginx/conf.d/proxy2.conf"
CERT_TARGET="/etc/nginx/certs"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0" >&2
    exit 1
fi

for file in "$CONFIG_SOURCE" "$CERT_SOURCE/ca.crt" "$CERT_SOURCE/proxy2.crt" "$CERT_SOURCE/proxy2.key" "$CERT_SOURCE/proxy1-client.crt"; do
    if [[ ! -f "$file" ]]; then
        echo "Required deployment file is missing: $file" >&2
        exit 1
    fi
done

openssl verify -CAfile "$CERT_SOURCE/ca.crt" -purpose sslserver \
    -verify_hostname cn-sso-config.lb.abc.com "$CERT_SOURCE/proxy2.crt"
openssl verify -CAfile "$CERT_SOURCE/ca.crt" -purpose sslclient \
    "$CERT_SOURCE/proxy1-client.crt"

cert_public_key="$(openssl x509 -in "$CERT_SOURCE/proxy2.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d ' ' -f 1)"
key_public_key="$(openssl pkey -in "$CERT_SOURCE/proxy2.key" -pubout -outform DER | sha256sum | cut -d ' ' -f 1)"
if [[ "$cert_public_key" != "$key_public_key" ]]; then
    echo "proxy2.crt does not match proxy2.key" >&2
    exit 1
fi

if [[ ! -d /etc/nginx ]]; then
    echo "NGINX configuration directory does not exist: /etc/nginx" >&2
    exit 1
fi

mkdir -p /var/backups
BACKUP_DIR="$(mktemp -d /var/backups/nginx-proxy2.XXXXXXXX)"
chmod 700 "$BACKUP_DIR"
CHANGED=0

rollback() {
    local name target result=0
    for name in proxy2.conf ca.crt proxy2.crt proxy2.key; do
        if [[ "$name" == "proxy2.conf" ]]; then
            target="$CONFIG_TARGET"
        else
            target="$CERT_TARGET/$name"
        fi

        if [[ -e "$BACKUP_DIR/$name" ]]; then
            cp -a "$BACKUP_DIR/$name" "$target" || result=1
        else
            rm -f "$target" || result=1
        fi
    done
    return "$result"
}

on_error() {
    local status=$1
    trap - ERR
    if [[ "$CHANGED" -eq 1 ]]; then
        echo "Deployment failed; restoring previous files." >&2
        if rollback; then
            echo "Previous files restored." >&2
            if nginx -t && systemctl reload nginx; then
                echo "Restored NGINX configuration reloaded." >&2
            else
                echo "Could not validate or reload the restored configuration; inspect NGINX before retrying." >&2
            fi
        else
            echo "Rollback was incomplete. Backup files are in $BACKUP_DIR" >&2
        fi
    fi
    exit "$status"
}
trap 'on_error "$?"' ERR

if [[ -f "$CONFIG_TARGET" ]]; then
    cp -a "$CONFIG_TARGET" "$BACKUP_DIR/proxy2.conf"
fi
for name in ca.crt proxy2.crt proxy2.key; do
    if [[ -f "$CERT_TARGET/$name" ]]; then
        cp -a "$CERT_TARGET/$name" "$BACKUP_DIR/$name"
    fi
done

if [[ ! -d "$CERT_TARGET" ]]; then
    install -d -o root -g root -m 755 "$CERT_TARGET"
fi

CHANGED=1
install -o root -g root -m 644 "$CERT_SOURCE/ca.crt" "$CERT_TARGET/ca.crt"
install -o root -g root -m 644 "$CERT_SOURCE/proxy2.crt" "$CERT_TARGET/proxy2.crt"
install -o root -g root -m 600 "$CERT_SOURCE/proxy2.key" "$CERT_TARGET/proxy2.key"
install -o root -g root -m 644 "$CONFIG_SOURCE" "$CONFIG_TARGET"

nginx -t
systemctl reload nginx
CHANGED=0
trap - ERR

echo "proxy2 configuration installed and NGINX reloaded."
echo "Backups are in $BACKUP_DIR"
