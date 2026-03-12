#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  capture_seed_from_container.sh \
    --fuzzer aflnet \
    --target QUIC/ngtcp2 \
    --version 28d3126 \
    [--server-port 4433] \
    [--transport udp|tcp] \
    [--server-cmd '...'] \
    [--client-cmd '...'] \
    [--inside-workdir /home/user/target/aflnet/ngtcp2/examples] \
    [--seed-dir subjects/QUIC/ngtcp2/seed] \
    [--seed-replay-dir subjects/QUIC/ngtcp2/seed-replay] \
    [--seed-name InitCH_HandFin_VNCID_1] \
    [--capture-time 8] \
    [--keep-container]

Notes:
- If --server-cmd/--client-cmd are omitted and target=QUIC/ngtcp2, built-in defaults are used.
- seed output is <seed-name>.raw
- seed-replay output is <seed-name>.lenpref.raw (aflnet 4-byte little-endian length prefix)
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SKILL_DIR}/../.." && pwd)"

fuzzer=""
target=""
version=""
server_port="4433"
transport=""
server_cmd=""
client_cmd=""
inside_workdir=""
seed_dir=""
seed_replay_dir=""
seed_name=""
capture_time="8"
keep_container="0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fuzzer) fuzzer="$2"; shift 2 ;;
        --target) target="$2"; shift 2 ;;
        --version) version="$2"; shift 2 ;;
        --server-port) server_port="$2"; shift 2 ;;
        --transport) transport="$2"; shift 2 ;;
        --server-cmd) server_cmd="$2"; shift 2 ;;
        --client-cmd) client_cmd="$2"; shift 2 ;;
        --inside-workdir) inside_workdir="$2"; shift 2 ;;
        --seed-dir) seed_dir="$2"; shift 2 ;;
        --seed-replay-dir) seed_replay_dir="$2"; shift 2 ;;
        --seed-name) seed_name="$2"; shift 2 ;;
        --capture-time) capture_time="$2"; shift 2 ;;
        --keep-container) keep_container="1"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$fuzzer" || -z "$target" || -z "$version" ]]; then
    usage
    exit 1
fi

protocol="${target%/*}"
impl="${target##*/}"
image="$(echo "pingu-${fuzzer}-${protocol}-${impl}:${version}" | tr 'A-Z' 'a-z')"

if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Image not found: $image" >&2
    exit 1
fi

if [[ -z "$transport" ]]; then
    case "$protocol" in
        QUIC) transport="udp" ;;
        TLS|HTTP|FTP|SMTP|SSH|RTSP|SIP) transport="tcp" ;;
        *) transport="tcp" ;;
    esac
fi

if [[ -z "$seed_dir" ]]; then
    seed_dir="${REPO_ROOT}/subjects/${target}/seed"
fi
if [[ -z "$seed_replay_dir" ]]; then
    seed_replay_dir="${REPO_ROOT}/subjects/${target}/seed-replay"
fi
mkdir -p "$seed_dir" "$seed_replay_dir"

if [[ -z "$seed_name" ]]; then
    seed_name="$(echo "${target}-${version}" | tr '/:' '__')"
fi

if [[ "$target" == "QUIC/ngtcp2" ]]; then
    default_workdir="/home/user/target/${fuzzer}/ngtcp2"
    default_server_cmd="./examples/wsslserver 127.0.0.1 ${server_port} /home/user/profuzzbench/cert/server.key /home/user/profuzzbench/cert/fullchain.crt --initial-pkt-num=0"
    default_client_cmd="./examples/wsslclient --no-quic-dump --no-http-dump --exit-on-all-streams-close 127.0.0.1 ${server_port} https://127.0.0.1/"
    inside_workdir="${inside_workdir:-$default_workdir}"
    server_cmd="${server_cmd:-$default_server_cmd}"
    client_cmd="${client_cmd:-$default_client_cmd}"
fi

if [[ -z "$inside_workdir" || -z "$server_cmd" || -z "$client_cmd" ]]; then
    echo "For target ${target}, please provide --inside-workdir --server-cmd --client-cmd" >&2
    exit 1
fi

cname="seedcap-$(echo "${fuzzer}-${protocol}-${impl}" | tr 'A-Z/' 'a-z-')-$(date +%s)"
host_tmp="$(mktemp -d "${REPO_ROOT}/temp/seedcap.XXXXXX")"
container_keep_flag="--rm"
if [[ "$keep_container" == "1" ]]; then
    container_keep_flag=""
fi

cleanup() {
    set +e
    docker exec --user 0 "$cname" bash -lc 'pkill -INT -f tcpdump || true; pkill -INT -f wsslserver || true' >/dev/null 2>&1 || true
    if [[ "$keep_container" != "1" ]]; then
        docker rm -f "$cname" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

echo "[+] Starting container: $cname"
docker run -d $container_keep_flag \
    --name "$cname" \
    --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt seccomp=unconfined \
    -v "${REPO_ROOT}:/home/user/profuzzbench" \
    "$image" \
    /bin/bash -lc "sleep infinity" >/dev/null

echo "[+] Starting server"
docker exec "$cname" /bin/bash -lc "cd '${inside_workdir}' && (${server_cmd}) > /tmp/seed_server.log 2>&1 & echo \$! > /tmp/seed_server.pid"
sleep 1

echo "[+] Starting tcpdump"
docker exec --user 0 -d "$cname" /bin/bash -lc "tcpdump -i any -s 0 -w /tmp/seed_capture.pcap '(tcp or udp) and port ${server_port}' > /tmp/seed_tcpdump.log 2>&1"
sleep 1

echo "[+] Running client"
docker exec "$cname" /bin/bash -lc "cd '${inside_workdir}' && timeout 20s ${client_cmd}" >"${host_tmp}/client.stdout.log" 2>"${host_tmp}/client.stderr.log" || true

sleep "$capture_time"
docker exec --user 0 "$cname" /bin/bash -lc "pkill -INT -f 'tcpdump -i any' || true"
sleep 1

if ! docker exec "$cname" /bin/bash -lc "test -f /tmp/seed_capture.pcap"; then
    echo "[!] tcpdump did not produce /tmp/seed_capture.pcap" >&2
    docker exec "$cname" /bin/bash -lc "cat /tmp/seed_tcpdump.log 2>/dev/null || true" >&2
    exit 1
fi

docker cp "$cname:/tmp/seed_capture.pcap" "${host_tmp}/seed_capture.pcap"
docker cp "$cname:/tmp/seed_server.log" "${host_tmp}/seed_server.log" >/dev/null 2>&1 || true
docker cp "$cname:/tmp/seed_tcpdump.log" "${host_tmp}/seed_tcpdump.log" >/dev/null 2>&1 || true

seed_path="${seed_dir}/${seed_name}.raw"
seed_replay_path="${seed_replay_dir}/${seed_name}.lenpref.raw"

echo "[+] Building seed files"
python3 "${SCRIPT_DIR}/extract_client_payloads_from_pcap.py" \
    --pcap "${host_tmp}/seed_capture.pcap" \
    --transport "$transport" \
    --server-port "$server_port" \
    --server-ip 127.0.0.1 \
    --seed-path "$seed_path" \
    --seed-replay-path "$seed_replay_path" || {
        echo "[!] Failed to extract payloads, debug logs below:" >&2
        echo "--- client.stderr.log ---" >&2
        cat "${host_tmp}/client.stderr.log" >&2 || true
        echo "--- seed_server.log ---" >&2
        cat "${host_tmp}/seed_server.log" >&2 || true
        echo "--- seed_tcpdump.log ---" >&2
        cat "${host_tmp}/seed_tcpdump.log" >&2 || true
        exit 1
    }

echo "[+] Done"
echo "    pcap: ${host_tmp}/seed_capture.pcap"
echo "    seed: ${seed_path}"
echo "    seed-replay: ${seed_replay_path}"
echo "    logs: ${host_tmp}"
