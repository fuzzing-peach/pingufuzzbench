---
name: init-seed-capture
description: Initialize protocol-valid seed corpora by launching a built target container, running a same-protocol client/server handshake, capturing packets with tcpdump, extracting client->server payload, and generating both raw `seed` and aflnet length-prefixed `seed-replay` files. Use when given fuzzer name, target program (PROTO/IMPL), and version tag, and you need reproducible initial seeds.
---

# Init Seed Capture

## Goal

Generate valid initial corpus files directly from real protocol traffic:
1. `seed/<name>.raw`
2. `seed-replay/<name>.lenpref.raw` (aflnet replay format: 4-byte little-endian length + payload)

## Scripts

1. `scripts/capture_seed_from_container.sh`
- Start container from `pingu-<fuzzer>-<protocol>-<impl>:<version>`.
- Start server and client inside container.
- Run `tcpdump` and export pcap/logs.
- Call parser to emit seed files.

2. `scripts/extract_client_payloads_from_pcap.py`
- Parse pcap (`EN10MB/SLL/SLL2/RAW/NULL`).
- Keep only client->server payload packets (TCP or UDP).
- Write both raw seed and replayable seed.

## Standard Workflow

1. Ensure image already exists, e.g. `pingu-aflnet-quic-ngtcp2:28d3126`.
2. Run capture script with fuzzer/target/version.
3. Verify `seed` and `seed-replay` output files.
4. If target is not `QUIC/ngtcp2`, provide explicit `--inside-workdir`, `--server-cmd`, `--client-cmd`.

## Quick Start

### QUIC/ngtcp2 (built-in defaults)
```bash
.skills/init-seed-capture/scripts/capture_seed_from_container.sh \
  --fuzzer aflnet \
  --target QUIC/ngtcp2 \
  --version 28d3126 \
  --seed-name InitCH_HandFin_VNCID_1
```

This generates:
1. `subjects/QUIC/ngtcp2/seed/InitCH_HandFin_VNCID_1.raw`
2. `subjects/QUIC/ngtcp2/seed-replay/InitCH_HandFin_VNCID_1.lenpref.raw`

### Generic target (explicit commands)
```bash
.skills/init-seed-capture/scripts/capture_seed_from_container.sh \
  --fuzzer aflnet \
  --target TLS/OpenSSL \
  --version 3.0.0 \
  --transport tcp \
  --server-port 4433 \
  --inside-workdir /home/user/target/aflnet/openssl \
  --server-cmd "apps/openssl s_server -accept 4433 -cert /home/user/profuzzbench/cert/fullchain.crt -key /home/user/profuzzbench/cert/server.key -www" \
  --client-cmd "echo | apps/openssl s_client -connect 127.0.0.1:4433 -quiet" \
  --seed-name tls_handshake_1
```

Use the same OpenSSL client pattern for other TLS implementations when protocol-compatible.

## Parameters

Required:
1. `--fuzzer`: e.g. `aflnet`
2. `--target`: `PROTO/IMPL`, e.g. `QUIC/ngtcp2`
3. `--version`: image tag suffix, e.g. `28d3126`

Common optional:
1. `--server-port`: default `4433`
2. `--transport`: `tcp|udp` (auto by protocol if omitted)
3. `--seed-dir`, `--seed-replay-dir`: custom output directories
4. `--seed-name`: output basename
5. `--capture-time`: extra capture seconds after client run
6. `--keep-container`: do not auto-remove container

For non-default targets:
1. `--inside-workdir`
2. `--server-cmd`
3. `--client-cmd`

## Expected Output

1. Pcap file saved under `temp/seedcap.*`.
2. Raw seed file in `seed/`.
3. Replayable seed file in `seed-replay/`.
4. Client/server/tcpdump logs for troubleshooting.

## Troubleshooting

1. `Image not found`: build first with `scripts/build.sh`.
2. `No client->server payload found`: adjust client command, port, or capture time.
3. Empty TCP payloads: ensure client sends app data after handshake.
4. Permission issues: run with a user that can use Docker.
