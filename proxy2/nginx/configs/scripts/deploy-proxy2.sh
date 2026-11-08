#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
CERT_SOURCE="$SOURCE_DIR/configs/certs"
CA_DIR="$CERT_SOURCE/ca"
CA_CERT_SOURCE="$CA_DIR/ca.crt"
CA_KEY_SOURCE="$CA_DIR/ca.key"
CONFIG_SOURCE="$SOURCE_DIR/configs/proxy2.conf"
CONFIG_TARGET="/etc/nginx/conf.d/proxy2.conf"
CERT_TARGET="/etc/nginx/certs"
CA_TARGET="$CERT_TARGET/ca/ca.crt"
LOG_DIR="$SOURCE_DIR/logs"
ACCESS_LOG="$LOG_DIR/proxy2_access.log"
ERROR_LOG="$LOG_DIR/proxy2_error.log"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0" >&2
    exit 1
fi

for file in "$CA_CERT_SOURCE" "$CA_KEY_SOURCE"; do
    if [[ ! -f "$file" ]]; then
        echo "Required deployment file is missing: $file" >&2
        exit 1
    fi
done

if [[ ! -d /etc/nginx/conf.d ]]; then
    echo "NGINX configuration directory does not exist: /etc/nginx/conf.d" >&2
    exit 1
fi

if [[ ! -d "$CERT_TARGET" ]]; then
    echo "NGINX certificate directory does not exist: $CERT_TARGET" >&2
    exit 1
fi

openssl x509 -in "$CA_CERT_SOURCE" -noout >/dev/null
openssl pkey -in "$CA_KEY_SOURCE" -noout >/dev/null

ca_public_key="$(openssl x509 -in "$CA_CERT_SOURCE" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d ' ' -f 1)"
ca_private_key="$(openssl pkey -in "$CA_KEY_SOURCE" -pubout -outform DER | sha256sum | cut -d ' ' -f 1)"
if [[ "$ca_public_key" != "$ca_private_key" ]]; then
    echo "CA certificate does not match the CA private key in $CA_DIR" >&2
    exit 1
fi

if [[ -e "$CA_TARGET" ]] && ! cmp -s "$CA_CERT_SOURCE" "$CA_TARGET"; then
    echo "Installed CA differs from $CA_CERT_SOURCE; refusing to replace the trusted CA." >&2
    exit 1
fi

mkdir -p /var/backups
BACKUP_DIR="$(mktemp -d /var/backups/nginx-proxy2.XXXXXXXX)"
chmod 700 "$BACKUP_DIR"
WORK_DIR="$(mktemp -d /var/tmp/nginx-proxy2.XXXXXXXX)"
chmod 700 "$WORK_DIR"
trap 'rm -rf -- "$WORK_DIR"' EXIT

SOURCE_OWNER="$(stat -c '%u' "$SOURCE_DIR")"
SOURCE_GROUP="$(stat -c '%g' "$SOURCE_DIR")"
CA_CREATED=0
CHANGED=0

backup_file() {
    local path="$1"
    local name="$2"
    if [[ -f "$path" ]]; then
        cp -a "$path" "$BACKUP_DIR/$name"
    fi
}

restore_file() {
    local path="$1"
    local name="$2"
    if [[ -f "$BACKUP_DIR/$name" ]]; then
        cp -a "$BACKUP_DIR/$name" "$path"
    else
        rm -f -- "$path"
    fi
}

rollback() {
    local result=0
    restore_file "$SOURCE_DIR/configs/certs/proxy2.crt" source-proxy2.crt || result=1
    restore_file "$SOURCE_DIR/configs/certs/proxy2.key" source-proxy2.key || result=1
    restore_file "$CONFIG_SOURCE" source-proxy2.conf || result=1
    restore_file "$CONFIG_TARGET" proxy2.conf || result=1
    restore_file "$CERT_TARGET/proxy2.crt" installed-proxy2.crt || result=1
    restore_file "$CERT_TARGET/proxy2.key" installed-proxy2.key || result=1
    if [[ "$CA_CREATED" -eq 1 ]]; then
        rm -f -- "$CA_TARGET" || result=1
    fi
    return "$result"
}

on_error() {
    local status=$1
    trap - ERR
    if [[ "$CHANGED" -eq 1 ]]; then
        echo "Deployment failed; restoring previous proxy2 files." >&2
        if rollback; then
            echo "Previous proxy2 files restored." >&2
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

for name in source-proxy2.crt source-proxy2.key source-proxy2.conf \
    installed-proxy2.crt installed-proxy2.key proxy2.conf; do
    case "$name" in
        source-proxy2.conf) path="$CONFIG_SOURCE" ;;
        source-*) path="$CERT_SOURCE/${name#source-}" ;;
        installed-*) path="$CERT_TARGET/${name#installed-}" ;;
        proxy2.conf) path="$CONFIG_TARGET" ;;
    esac
    backup_file "$path" "$name"
done

cat > "$WORK_DIR/proxy2.conf" <<'NGINX_CONFIG'
upstream config_backend {
    server 10.0.10.9:443;
    keepalive 32;
}

upstream log_backend {
    server 10.0.10.9:443;
    keepalive 32;
}

server {
    listen 443 ssl http2;
    server_name cn-sso-config.lb.abc.com cn-sso-logging.lb.abc.com;

    access_log /home/uadmin/nginx/logs/proxy2_access.log;
    error_log /home/uadmin/nginx/logs/proxy2_error.log;

    ssl_certificate     /etc/nginx/certs/proxy2.crt;
    ssl_certificate_key /etc/nginx/certs/proxy2.key;
    ssl_client_certificate /etc/nginx/certs/ca/ca.crt;
    ssl_verify_client on;
    ssl_verify_depth 2;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /config/1.2.1/ssoconf.xml {
        if ($request_method != GET) {
            return 405;
        }

        proxy_pass https://config_backend/config/1.2.1/ssoconf.xml;
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        proxy_ssl_name sso-config.lb.abc.com;
        proxy_ssl_trusted_certificate /etc/nginx/certs/ca/ca.crt;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 2;
        proxy_set_header Host sso-config.lb.abc.com;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Connection "";
    }

    location = /sso/log {
        if ($request_method != POST) {
            return 405;
        }

        proxy_pass https://log_backend/sso/log;
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        proxy_ssl_name sso-logging.lb.abc.com;
        proxy_ssl_trusted_certificate /etc/nginx/certs/ca/ca.crt;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 2;
        proxy_set_header Host sso-logging.lb.abc.com;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header Connection "";
    }

    location / {
        return 404;
    }
}
NGINX_CONFIG

serial="$(openssl rand -hex 16)"
openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$WORK_DIR/proxy2.key" \
    -out "$WORK_DIR/proxy2.csr" \
    -subj "/CN=cn-sso-config.lb.abc.com" \
    -addext "subjectAltName=DNS:cn-sso-config.lb.abc.com,DNS:cn-sso-logging.lb.abc.com"
openssl x509 -req -in "$WORK_DIR/proxy2.csr" \
    -CA "$CA_CERT_SOURCE" \
    -CAkey "$CA_KEY_SOURCE" \
    -set_serial "0x$serial" \
    -out "$WORK_DIR/proxy2.crt" \
    -days 825 \
    -sha256 \
    -copy_extensions copyall

openssl verify -CAfile "$CA_CERT_SOURCE" -purpose sslserver \
    -verify_hostname cn-sso-config.lb.abc.com "$WORK_DIR/proxy2.crt"
openssl verify -CAfile "$CA_CERT_SOURCE" -purpose sslserver \
    -verify_hostname cn-sso-logging.lb.abc.com "$WORK_DIR/proxy2.crt"

cert_public_key="$(openssl x509 -in "$WORK_DIR/proxy2.crt" -pubkey -noout | openssl pkey -pubin -outform DER | sha256sum | cut -d ' ' -f 1)"
key_public_key="$(openssl pkey -in "$WORK_DIR/proxy2.key" -pubout -outform DER | sha256sum | cut -d ' ' -f 1)"
if [[ "$cert_public_key" != "$key_public_key" ]]; then
    echo "Generated proxy2.crt does not match proxy2.key" >&2
    exit 1
fi

CHANGED=1
install -d -o root -g adm -m 755 "$LOG_DIR"
touch "$ACCESS_LOG" "$ERROR_LOG"
chown root:adm "$ACCESS_LOG" "$ERROR_LOG"
chmod 640 "$ACCESS_LOG" "$ERROR_LOG"
if [[ ! -e "$CA_TARGET" ]]; then
    install -d -o root -g root -m 755 "$CERT_TARGET/ca"
    CA_CREATED=1
    install -o root -g root -m 644 "$CA_CERT_SOURCE" "$CA_TARGET"
fi
install -o "$SOURCE_OWNER" -g "$SOURCE_GROUP" -m 644 "$WORK_DIR/proxy2.crt" "$CERT_SOURCE/proxy2.crt"
install -o "$SOURCE_OWNER" -g "$SOURCE_GROUP" -m 600 "$WORK_DIR/proxy2.key" "$CERT_SOURCE/proxy2.key"
install -o root -g root -m 644 "$WORK_DIR/proxy2.crt" "$CERT_TARGET/proxy2.crt"
install -o root -g root -m 600 "$WORK_DIR/proxy2.key" "$CERT_TARGET/proxy2.key"
install -o "$SOURCE_OWNER" -g "$SOURCE_GROUP" -m 644 "$WORK_DIR/proxy2.conf" "$CONFIG_SOURCE"
install -o root -g root -m 644 "$WORK_DIR/proxy2.conf" "$CONFIG_TARGET"

nginx -t
systemctl reload nginx
CHANGED=0
trap - ERR

echo "proxy2 configuration and regenerated server certificate/key installed; NGINX reloaded."
echo "CA files in $CA_DIR were not modified."
echo "Backups are in $BACKUP_DIR"
