#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CERT_SOURCE="$PROJECT_DIR/configs/certs"

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this script with sudo: sudo bash $0" >&2
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "NGINX is not installed. Install NGINX before deploying the origin." >&2
    exit 1
fi

for file in \
    "$PROJECT_DIR/sso_origin.py" \
    "$PROJECT_DIR/configs/origin.conf" \
    "$PROJECT_DIR/configs/sso-origin.service" \
    "$PROJECT_DIR/configs/sso-origin.logrotate" \
    "$CERT_SOURCE/ca.crt" \
    "$CERT_SOURCE/ca.key"; do
    if [[ ! -f "$file" ]]; then
        echo "Required deployment file is missing: $file" >&2
        exit 1
    fi
done

if [[ ! -f /etc/nginx/certs/sso-origin.crt || ! -f /etc/nginx/certs/sso-origin.key ]]; then
    bash "$CERT_SOURCE/generate_origin_cert.sh"
fi

openssl verify -CAfile "$CERT_SOURCE/ca.crt" -purpose sslserver \
    -verify_hostname sso-config.lb.abc.com /etc/nginx/certs/sso-origin.crt
openssl verify -CAfile "$CERT_SOURCE/ca.crt" -purpose sslserver \
    -verify_hostname sso-logging.lb.abc.com /etc/nginx/certs/sso-origin.crt

install -d -o uadmin -g uadmin -m 755 "$PROJECT_DIR/root"
install -d -o uadmin -g uadmin -m 700 "$PROJECT_DIR/root/bigquery"
install -d -o uadmin -g uadmin -m 755 "$PROJECT_DIR/logs"
install -d -o uadmin -g uadmin -m 700 "$PROJECT_DIR/sso-logs"
install -d -o root -g root -m 755 /opt/sso-origin
install -o root -g root -m 644 "$PROJECT_DIR/sso_origin.py" /opt/sso-origin/sso_origin.py
install -o root -g root -m 644 "$PROJECT_DIR/configs/origin.conf" /etc/nginx/conf.d/sso-origin.conf
install -o root -g root -m 644 "$PROJECT_DIR/configs/sso-origin.service" /etc/systemd/system/sso-origin.service
install -o root -g root -m 644 "$PROJECT_DIR/configs/sso-origin.logrotate" /etc/logrotate.d/sso-origin
install -o root -g root -m 644 "$PROJECT_DIR/configs/origin-access.logrotate" /etc/logrotate.d/sso-origin-access

for log_file in \
    "$PROJECT_DIR/logs/sso-config_get_access.log" \
    "$PROJECT_DIR/logs/sso-logging_post_access.log"; do
    if [[ ! -e "$log_file" ]]; then
        install -o root -g adm -m 640 /dev/null "$log_file"
    fi
done

nginx -t
systemctl daemon-reload
systemctl enable --now sso-origin.service
systemctl restart sso-origin.service
systemctl enable --now nginx
systemctl reload nginx

echo "SSO origin deployed on HTTPS port 443."
echo "Config GET access log: $PROJECT_DIR/logs/sso-config_get_access.log"
echo "Logging POST access log: $PROJECT_DIR/logs/sso-logging_post_access.log"
echo "Uploaded files: $PROJECT_DIR/root/bigquery"
echo "Place the XML file at $PROJECT_DIR/root/config/1.2.1/ssoconf.xml."
