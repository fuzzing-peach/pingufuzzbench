#!/usr/bin/env bash
set -euo pipefail

CERT_DIR="${CERT_DIR:-/opt/cert}"
LOG_DIR="${LOG_DIR:-/opt/repro-logs}"
SERVER_PORT="${SERVER_PORT:-4433}"
SERVER_TIMEOUT="${SERVER_TIMEOUT:-20}"
CLIENT_TIMEOUT="${CLIENT_TIMEOUT:-12}"
CLIENT_USE_W="${CLIENT_USE_W:-1}"

mkdir -p "${CERT_DIR}" "${LOG_DIR}"

if [[ ! -f "${CERT_DIR}/ca.crt" || ! -f "${CERT_DIR}/ca.key" ]]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
        -subj "/CN=Repro-CA" \
        -keyout "${CERT_DIR}/ca.key" \
        -out "${CERT_DIR}/ca.crt" >/dev/null 2>&1
fi

if [[ ! -f "${CERT_DIR}/server.key" || ! -f "${CERT_DIR}/server.crt" ]]; then
    openssl req -newkey rsa:2048 -nodes \
        -subj "/CN=localhost" \
        -keyout "${CERT_DIR}/server.key" \
        -out "${CERT_DIR}/server.csr" >/dev/null 2>&1

    openssl x509 -req -in "${CERT_DIR}/server.csr" \
        -CA "${CERT_DIR}/ca.crt" \
        -CAkey "${CERT_DIR}/ca.key" \
        -CAcreateserial \
        -out "${CERT_DIR}/server.crt" \
        -days 365 -sha256 >/dev/null 2>&1

fi

if [[ ! -f "${CERT_DIR}/fullchain.crt" ]]; then
    cat "${CERT_DIR}/server.crt" "${CERT_DIR}/ca.crt" > "${CERT_DIR}/fullchain.crt"
fi

rm -f "${LOG_DIR}/server.out" "${LOG_DIR}/server.err" "${LOG_DIR}/client.out" "${LOG_DIR}/client.err"

(
    cd /opt/wolfssl
    timeout "${SERVER_TIMEOUT}s" ./examples/server/server \
        -C 10 \
        -p "${SERVER_PORT}" \
        -c "${CERT_DIR}/fullchain.crt" \
        -k "${CERT_DIR}/server.key" \
        -L C:h2,http/1.1 \
        -s \
        -e -d -r -V \
        > "${LOG_DIR}/server.out" \
        2> "${LOG_DIR}/server.err"
) &
server_pid=$!

sleep 1

client_args=(
    -r
    -p "${SERVER_PORT}"
    -A "${CERT_DIR}/ca.crt"
    -L C:h2,http/1.1
    -s
)

if [[ "${CLIENT_USE_W}" == "1" ]]; then
    client_args+=( -W 1 )
fi

set +e
(
    cd /opt/wolfssl
    timeout "${CLIENT_TIMEOUT}s" ./examples/client/client \
        "${client_args[@]}" \
        > "${LOG_DIR}/client.out" \
        2> "${LOG_DIR}/client.err"
)
client_rc=$?
wait "${server_pid}"
server_rc=$?
set -e

echo "CLIENT_RC=${client_rc}"
echo "SERVER_RC=${server_rc}"
echo "LOG_DIR=${LOG_DIR}"
echo "----- client.err -----"
cat "${LOG_DIR}/client.err" || true
echo "----- server.err -----"
cat "${LOG_DIR}/server.err" || true

if grep -q "AddressSanitizer" "${LOG_DIR}/server.err"; then
    echo "[+] Reproduced: ASAN crash observed in server"
else
    echo "[-] No ASAN crash observed"
fi
