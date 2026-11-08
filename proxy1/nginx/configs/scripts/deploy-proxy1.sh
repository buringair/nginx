#!/usr/bin/env bash
set -Eeuo pipefail

if (( EUID != 0 )); then
    exec sudo -- bash "$0" "$@"
fi

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIGS_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly CONFIG_TEMPLATE="$CONFIGS_DIR/archive/proxy1.conf"
readonly SOURCE_CONFIG="$CONFIGS_DIR/proxy1.conf"
readonly SOURCE_CERTS="$CONFIGS_DIR/certs"
readonly CA_DIR="$SOURCE_CERTS/ca"
readonly CA_KEY="$CA_DIR/ca.key"
readonly SOURCE_UID="$(stat -c '%u' "$CONFIGS_DIR")"
readonly SOURCE_GID="$(stat -c '%g' "$CONFIGS_DIR")"
readonly CONFIG_TARGET="/etc/nginx/conf.d/abc-sso-proxy1.conf"
readonly CERT_TARGET="/etc/nginx/certs"
readonly CA_CERT="$CA_DIR/ca.crt"
readonly CA_SERIAL="$CA_DIR/ca.srl"
readonly LOG_DIR="$CONFIGS_DIR/logs"

work_dir=""
changes_started=0
deployment_succeeded=0

finish() {
    local result=$?
    local restart_result=0
    trap - EXIT

    if (( changes_started && ! deployment_succeeded )); then
        restore_file "$SOURCE_CONFIG" "source-proxy1.conf" || result=1
        for file in proxy1.crt proxy1.key proxy1-client.crt proxy1-client.key; do
            restore_file "$SOURCE_CERTS/$file" "source-$file" || result=1
        done
        restore_file "$CA_SERIAL" "ca.srl" || result=1
        for file in proxy1.crt proxy1.key proxy1-client.crt proxy1-client.key; do
            restore_file "$CERT_TARGET/$file" "$file" || result=1
        done
        restore_file "$CONFIG_TARGET" "abc-sso-proxy1.conf" || result=1
    fi

    if (( changes_started )); then
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
        rm -f -- "$target"
        cp -a -- "$work_dir/$backup_name" "$target"
    else
        rm -f -- "$target"
    fi
}

issue_leaf_pair() {
    local name=$1
    local subject=$2
    local extension_section=$3
    local extension_body=$4
    local key="$work_dir/$name.key"
    local csr="$work_dir/$name.csr"
    local certificate="$work_dir/$name.crt"
    local serial_options=()

    if [[ -f "$CA_SERIAL" ]]; then
        serial_options=(-CAserial "$CA_SERIAL")
    else
        serial_options=(-CAcreateserial)
    fi

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$key" -out "$csr" -subj "$subject"
    cat > "$work_dir/$name.ext" <<EOF
[$extension_section]
$extension_body
EOF
    openssl x509 -req -in "$csr" \
        -CA "$CA_CERT" -CAkey "$CA_KEY" "${serial_options[@]}" \
        -out "$certificate" -days 825 -sha256 \
        -extfile "$work_dir/$name.ext" -extensions "$extension_section"
    chmod 0600 "$key"
}

ensure_leaf_pair() {
    local name=$1
    local subject=$2
    local extension_section=$3
    local extension_body=$4
    local certificate="$SOURCE_CERTS/$name.crt"
    local private_key="$SOURCE_CERTS/$name.key"

    if [[ -e "$certificate" || -e "$private_key" ]]; then
        [[ -f "$certificate" && -f "$private_key" ]] ||
            fail "Incomplete certificate/key pair for $name; refusing to overwrite either file."
        return
    fi

    issue_leaf_pair "$name" "$subject" "$extension_section" "$extension_body"
    install -o "$SOURCE_UID" -g "$SOURCE_GID" \
        -m 0644 "$work_dir/$name.crt" "$certificate"
    install -o "$SOURCE_UID" -g "$SOURCE_GID" \
        -m 0600 "$work_dir/$name.key" "$private_key"
}

if ! command -v nginx >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 || fail "Nginx is missing and apt-get is unavailable."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
fi
nginx -v
systemctl cat nginx.service >/dev/null

[[ -f "$CA_CERT" && -f "$CA_KEY" ]] ||
    fail "CA certificate and private key must exist under $CA_DIR; this script will not create or replace them."
openssl x509 -in "$CA_CERT" -noout -checkend 0 >/dev/null
openssl x509 -in "$CA_CERT" -noout >/dev/null
openssl pkey -in "$CA_KEY" -noout >/dev/null
openssl x509 -in "$CA_CERT" -noout -text | grep -q 'CA:TRUE' ||
    fail "Certificate at $CA_CERT is not a CA certificate."

ca_cert_public_key="$(
    openssl x509 -in "$CA_CERT" -pubkey -noout |
        openssl pkey -pubin -outform DER |
        sha256sum | awk '{print $1}'
)"
ca_private_public_key="$(
    openssl pkey -in "$CA_KEY" -pubout -outform DER |
        sha256sum | awk '{print $1}'
)"
[[ "$ca_cert_public_key" == "$ca_private_public_key" ]] ||
    fail "CA certificate and private key do not match."

mkdir -p "$SOURCE_CERTS"
work_dir="$(mktemp -d)"
for file in proxy1.crt proxy1.key proxy1-client.crt proxy1-client.key; do
    backup_file "$SOURCE_CERTS/$file" "source-$file"
    backup_file "$CERT_TARGET/$file" "$file"
done
backup_file "$SOURCE_CONFIG" "source-proxy1.conf"
backup_file "$CONFIG_TARGET" "abc-sso-proxy1.conf"
backup_file "$CA_SERIAL" "ca.srl"
changes_started=1

if [[ ! -f "$SOURCE_CONFIG" ]]; then
    [[ -f "$CONFIG_TEMPLATE" ]] ||
        fail "Missing proxy1 config and template: $SOURCE_CONFIG, $CONFIG_TEMPLATE"
    install -o "$SOURCE_UID" -g "$SOURCE_GID" \
        -m 0644 "$CONFIG_TEMPLATE" "$SOURCE_CONFIG"
fi

ensure_leaf_pair proxy1 \
    "/CN=sso-config.lb.abc.cn" \
    proxy1_server \
    $'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:sso-config.lb.abc.cn,DNS:sso-logging.lb.abc.cn'
ensure_leaf_pair proxy1-client \
    "/CN=proxy1-client" \
    proxy1_client \
    $'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth'

for file in proxy1.crt proxy1-client.crt; do
    openssl x509 -in "$SOURCE_CERTS/$file" -noout -checkend 0 >/dev/null
done
for file in proxy1.key proxy1-client.key; do
    openssl pkey -in "$SOURCE_CERTS/$file" -noout >/dev/null
done
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

[[ -d "$LOG_DIR" ]] || install -d -o www-data -g adm -m 0750 "$LOG_DIR"
install -d -m 0755 "$CERT_TARGET" /etc/nginx/conf.d

install -o root -g root -m 0644 "$SOURCE_CERTS/proxy1.crt" "$CERT_TARGET/proxy1.crt"
install -o root -g root -m 0600 "$SOURCE_CERTS/proxy1.key" "$CERT_TARGET/proxy1.key"
install -o root -g root -m 0644 "$SOURCE_CERTS/proxy1-client.crt" "$CERT_TARGET/proxy1-client.crt"
install -o root -g root -m 0600 "$SOURCE_CERTS/proxy1-client.key" "$CERT_TARGET/proxy1-client.key"
install -o root -g root -m 0644 "$SOURCE_CONFIG" "$CONFIG_TARGET"
nginx -t

deployment_succeeded=1
printf 'Proxy1 deployment checks passed. The CA certificate and private key under %s were left unchanged.\n' "$CA_DIR"
