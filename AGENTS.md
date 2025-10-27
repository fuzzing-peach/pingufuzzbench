# Repository Guidelines

## Project Structure & Module Organization
PinguFuzzBench stores fuzzing subjects under `subjects/`, grouped by protocol (e.g., `subjects/TLS/OpenSSL/` with `config.sh` and YAML configs). Core automation sits in `scripts/`; experiment artefacts go to `output/`, and documentation lives in `docs/` and `figures/`. Use `patches/` for vendor fixes and `tests/` for harness fixtures. Mirror existing casing when adding protocols so Docker lookups keep working.

## Build, Test, and Development Commands
- `./scripts/build-env.sh -f aflnet -- --network=host` builds the base image; pass proxy flags after `--`.
- `./scripts/dev.sh -f aflnet` opens an interactive container for debugging.
- `./scripts/build.sh -t TLS/OpenSSL -f ft -v <tag>` builds the runtime image for a protocol/fuzzer pair.
- `./scripts/run.sh -t TLS/OpenSSL -f aflnet -v <tag> -o output/<run>` starts fuzzing; add `--dry-run` to validate and `--times N` for batches.
- `./scripts/ci-build-run.sh -t TLS/OpenSSL -f aflnet -v <tag>` mirrors the CI pipeline.
- `./scripts/evaluate.sh output/<run>` reports coverage and crash stats.

## Coding Style & Naming Conventions
Shell tooling targets Bash with `set -e` and `set -o pipefail`; indent four spaces, quote expansions, and reuse `scripts/utils.sh` log helpers. Python analysis under `scripts/analysis/` follows PEP 8 with concise docstrings. Subject metadata stays lowercase (`pingu-source.yaml`, `ft-sink.yaml`) so Docker tags remain `pingu-<fuzzer>-<protocol>-<impl>`.

## Testing Guidelines
Build the runtime image and run a short fuzzing campaign for the touched subject before submitting. For harness tweaks, use `tests/select_empty_file.c` and `tests/select_dev_null.c` as references and compile with `clang -O2 tests/select_dev_null.c -o temp/select_dev_null`. Summarise coverage or crash deltas with `./scripts/evaluate.sh output/<run>` in the review notes.

## Commit & Pull Request Guidelines
Adopt the `<Type>: <subject>` prefix (`Fix: stateafl on gnutls`, `Feat: git clone to .git-cache`) and keep commits scoped to one fuzzer, script, or harness change. Pull requests should describe the scenario, list affected targets, link issues, and include the exact build/run/evaluate commands plus any crash or coverage evidence.

## Environment & Security Notes
`scripts/run.sh` requires `kernel.core_pattern=core`; set it via `echo core | sudo tee /proc/sys/kernel/core_pattern` before long sessions. Keep generated certificates, corpora, and binaries in `output/` or `temp/` and out of version control. Use the existing `--build-arg HTTP_PROXY=...` and `HTTPS_PROXY=...` flags instead of modifying scripts.
