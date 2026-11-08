#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
    exec sudo -- bash "$0" "$@"
fi

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIGS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SOURCE_CONFIG="$CONFIGS_DIR/proxy1.conf"
readonly SOURCE_CERTS="$CONFIGS_DIR/certs"
readonly CONFIG_TARGET="/etc/nginx/conf.d/abc-sso-proxy1.conf"
readonly CERT_TARGET="/etc/nginx/certs"
readonly CA_CERT="$SOURCE_CERTS/ca/ca.crt"

work_dir=""
changes_started=0
deployment_succeeded=0

finish() {
    local result=$?
    local restart_result=0
    trap - EXIT

    if (( changes_started && ! deployment_succeeded )); then
        for file in proxy1.crt proxy1.key proxy1-client.crt proxy1-client.key; do
            restore_file "$CERT_TARGET/$file" "$file" || result=1
        done
        restore_file "$CONFIG_TARGET" "abc-sso-proxy1.conf" || result=1
    fi

    if systemctl restart nginx; then
        systemctl is-active --quiet nginx || restart_result=$?
    else
        restart_result=$?
    fi

    if (( restart_result == 0 )); then
        printf 'Nginx restart check passed.\n'
    else
        printf 'ERROR: Nginx restart or active-state check failed.\n' >&2
        result=1
    fi

    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        rm -rf -- "$work_dir" || result=1
    fi

    exit "$result"
}
trap finish EXIT

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

backup_file() {
    local target=$1
    local backup_name=$2

    if [[ -e "$target" || -L "$target" ]]; then
        cp -a -- "$target" "$work_dir/$backup_name"
    fi
}

restore_file() {
    local target=$1
    local backup_name=$2

    if [[ -e "$work_dir/$backup_name" || -L "$work_dir/$backup_name" ]]; then
        cp -a -- "$work_dir/$backup_name" "$target"
    else
        rm -f -- "$target"
    fi
}

[[ -f "$SOURCE_CONFIG" ]] || fail "Missing proxy1 config: $SOURCE_CONFIG"
for file in proxy1.crt proxy1.key proxy1-client.crt proxy1-client.key; do
    [[ -f "$SOURCE_CERTS/$file" ]] || fail "Required certificate file is missing: $SOURCE_CERTS/$file"
done

if ! command -v nginx >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail "Nginx is missing and apt-get is unavailable."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
fi
nginx -v
systemctl cat nginx.service >/dev/null

[[ -f "$CA_CERT" ]] || fail "Required CA certificate must exist at $CA_CERT; it will not be created, copied, or changed."
openssl x509 -in "$CA_CERT" -noout >/dev/null

openssl x509 -in "$SOURCE_CERTS/proxy1.crt" -noout >/dev/null
openssl x509 -in "$SOURCE_CERTS/proxy1-client.crt" -noout >/dev/null
openssl pkey -in "$SOURCE_CERTS/proxy1.key" -noout >/dev/null
openssl pkey -in "$SOURCE_CERTS/proxy1-client.key" -noout >/dev/null
openssl x509 -in "$SOURCE_CERTS/proxy1.crt" -noout -checkhost sso-config.lb.abc.cn >/dev/null
openssl x509 -in "$SOURCE_CERTS/proxy1.crt" -noout -checkhost sso-logging.lb.abc.cn >/dev/null
openssl verify -CAfile "$CA_CERT" \
    "$SOURCE_CERTS/proxy1.crt" "$SOURCE_CERTS/proxy1-client.crt"

check_key_pair() {
    local certificate=$1
    local private_key=$2
    local cert_public_key
    local private_public_key

    cert_public_key="$(
        openssl x509 -in "$certificate" -pubkey -noout |
            openssl pkey -pubin -outform DER |
            sha256sum | awk '{print $1}'
    )"
    private_public_key="$(
        openssl pkey -in "$private_key" -pubout -outform DER |
            sha256sum | awk '{print $1}'
    )"
    [[ "$cert_public_key" == "$private_public_key" ]] ||
        fail "Certificate and private key do not match: $certificate"
}

check_key_pair "$SOURCE_CERTS/proxy1.crt" "$SOURCE_CERTS/proxy1.key"
check_key_pair "$SOURCE_CERTS/proxy1-client.crt" "$SOURCE_CERTS/proxy1-client.key"

work_dir="$(mktemp -d)"
install -d -m 0755 "$CERT_TARGET" /etc/nginx/conf.d
for file in proxy1.crt proxy1.key proxy1-client.crt proxy1-client.key; do
    backup_file "$CERT_TARGET/$file" "$file"
done
backup_file "$CONFIG_TARGET" "abc-sso-proxy1.conf"
changes_started=1

install -o root -g root -m 0644 "$SOURCE_CERTS/proxy1.crt" "$CERT_TARGET/proxy1.crt"
install -o root -g root -m 0600 "$SOURCE_CERTS/proxy1.key" "$CERT_TARGET/proxy1.key"
install -o root -g root -m 0644 "$SOURCE_CERTS/proxy1-client.crt" "$CERT_TARGET/proxy1-client.crt"
install -o root -g root -m 0600 "$SOURCE_CERTS/proxy1-client.key" "$CERT_TARGET/proxy1-client.key"
install -o root -g root -m 0644 "$SOURCE_CONFIG" "$CONFIG_TARGET"
nginx -t

deployment_succeeded=1
printf 'Proxy1 deployment checks passed. The CA under %s was left unchanged.\n' "$SOURCE_CERTS/ca"
