---
name: pfb-build-run
description: Build and run workflows for PinguFuzzBench with dockerized fuzzing targets. Use when tasks involve `scripts/build-env.sh`, `scripts/build.sh`, `scripts/run.sh`, proxy-aware builds, fixed version image tags, reproducible output directories, or manual `docker run` invocation for debugging and replay.
---

# PinguFuzzBench Build/Run

## Goal

Standardize three operations for one target/fuzzer pair:
1. Build fuzzer environment image (`build-env`)
2. Build target runtime image (`build`)
3. Launch fuzzing campaign (`run`)

Use this workflow to ensure consistent image naming, reproducible tags, and predictable output layout.

## Quick Workflow

1. Build env image.
```bash
./scripts/build-env.sh -f aflnet -- \
  --build-arg HTTP_PROXY=http://172.17.0.1:9870 \
  --build-arg HTTPS_PROXY=http://172.17.0.1:9870 \
  --build-arg ZH_CN=true
```

2. Build target image.
```bash
./scripts/build.sh -t QUIC/ngtcp2 -f aflnet -v 28d3126 -- \
  --build-arg HTTP_PROXY=http://172.17.0.1:9870 \
  --build-arg HTTPS_PROXY=http://172.17.0.1:9870 \
  --build-arg ZH_CN=true
```

3. Run fuzzing.
```bash
mkdir -p output/ngtcp2-aflnet-300s
./scripts/run.sh \
  -o output/ngtcp2-aflnet-300s \
  -t QUIC/ngtcp2 \
  -f aflnet \
  -v 28d3126 \
  --timeout 300 \
  --replay-step 1 \
  --gcov-step 1 -- -- -E
```

Expected effect:
1. Environment image `pingu-env-aflnet:latest` is available.
2. Runtime image `pingu-aflnet-quic-ngtcp2:28d3126` is available.
3. One or more containers run and write artifacts to `output/.../<container_name>/`.

## Parameter Guide

### `build-env.sh`
1. `-f <fuzzer>`: choose env dockerfile (`Dockerfile-env-<fuzzer>`), image is `pingu-env-<fuzzer>:latest`.
2. `-- ...`: pass raw docker build args (proxy, mirror, locale flags).
3. Typical effect: installs compiler/fuzzer toolchain and common dependencies.

### `build.sh`
1. `-t <PROTO/IMPL>`: target, e.g. `QUIC/ngtcp2`.
2. `-f <fuzzer>`: fuzzer variant, e.g. `aflnet`.
3. `-v <version>`: final image tag, should be fixed for reproducibility.
4. `--generator <name>`: only valid for `ft` or `pingu`.
5. `--flags <value>`: extra build controls when target config supports it.
6. `-- ...`: raw docker build args forwarded to `docker build`.
7. Typical effect: image named `pingu-<fuzzer>-<protocol>-<impl>:<version>`.

### `run.sh`
1. `-o <output_dir>`: host output root.
2. `-t/-f/-v`: select image `pingu-<fuzzer>-<protocol>-<impl>:<version>`.
3. `--timeout <sec>`: campaign duration.
4. `--times <N>`: number of parallel containers.
5. `--detached`: return immediately and wait in background.
6. `--cleanup`: remove containers after completion.
7. `--dry-run`: print generated `docker run` only.
8. `--replay-step`, `--gcov-step`: replay/coverage sampling interval.
9. `--cpu-affinity` or `--no-cpu`: CPU pinning policy.
10. `-- ...`: pass extra fuzzer args to `dispatch.sh`.

Expected effect:
1. Creates container-specific output directories.
2. Launches privileged fuzzing containers with mounted repo/output.
3. Writes `stdout.log`, `stderr.log`, queue/crashes/coverage artifacts.

## Image Naming Rules

1. Env image: `pingu-env-<fuzzer>:latest` (fallback `pingu-env:latest`).
2. Runtime image: `pingu-<fuzzer>-<protocol>-<impl>:<version>`.
3. Example:
`-t QUIC/ngtcp2 -f aflnet -v 28d3126` -> `pingu-aflnet-quic-ngtcp2:28d3126`.

## Manual Docker Commands

### Start env container (interactive debug)
```bash
docker run --rm -it \
  --name env-aflnet-debug \
  --user "$(id -u):$(id -g)" \
  -e HTTP_PROXY=http://172.17.0.1:9870 \
  -e HTTPS_PROXY=http://172.17.0.1:9870 \
  -v "$(pwd)":/home/user/profuzzbench \
  -w /home/user/profuzzbench \
  pingu-env-aflnet:latest \
  /bin/bash
```

### Start target container (manual run/replay)
```bash
OUT="$(pwd)/output/manual-ngtcp2"
mkdir -p "${OUT}"
docker run -it --rm --privileged \
  --cap-add=SYS_ADMIN --cap-add=SYS_RAWIO --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  --sysctl net.ipv4.tcp_tw_reuse=1 \
  --user "$(id -u):$(id -g)" \
  -e AFL_NO_AFFINITY=1 \
  -e USE_FAKE_ENV=1 \
  -e FAKE_RANDOM=1 \
  -e FAKERANDOM_SEED=1 \
  -e FAKE_TIME="2026-03-11 12:00:00" \
  -v /etc/localtime:/etc/localtime:ro \
  -v /etc/timezone:/etc/timezone:ro \
  -v "$(pwd)":/home/user/profuzzbench \
  -v "${OUT}":/tmp/fuzzing-output:rw \
  --mount type=tmpfs,destination=/tmp,tmpfs-mode=777 \
  --cpuset-cpus 0-3 \
  --shm-size=64G \
  --ulimit msgqueue=2097152000 \
  --memory=16g --cpus=4 \
  --name pingu-aflnet-quic-ngtcp2-manual \
  pingu-aflnet-quic-ngtcp2:28d3126 \
  /bin/bash
```

### Run same command as `run.sh` would dispatch
```bash
bash /home/user/profuzzbench/scripts/dispatch.sh \
  QUIC/ngtcp2 run aflnet 1 1 120 -- -E
```

## Verification Checklist

1. `docker images | grep pingu-env-aflnet`
2. `docker images | grep pingu-aflnet-quic-ngtcp2`
3. `docker ps -a --filter name=pingu-aflnet-quic-ngtcp2`
4. `ls -lah output/<run_name>/`
