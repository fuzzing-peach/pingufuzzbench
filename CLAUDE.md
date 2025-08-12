# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

PinguFuzzBench is a specialized benchmark for cryptographic network protocol fuzzing, focusing on encrypted protocols (TLS, SSH, QUIC, DTLS) while maintaining baseline plaintext protocols for comparison.

## Detailed Directory Structure

### 📁 Root Directory
- **README.md** - Main documentation with complete usage guide
- **pingu.yaml** - Pingu fuzzer configuration template
- **ft.yaml** - Fuzztruction configuration template
- **LICENSE** - Repository license
- **figures/** - Generated coverage plots and visualizations
- **docs/** - Architecture diagrams (pingubench.drawio.svg)

### 📁 subjects/ - Protocol Implementations
Organized by protocol type, each containing multiple implementations:

#### 📁 subjects/TLS/ - Transport Layer Security
- **OpenSSL/** - Most comprehensive TLS implementation
  - `config.sh` - Build/run functions for all fuzzers (AFLNet, StateAFL, SGFuzz, FT, Pingu)
  - `Dockerfile` - Container for standard fuzzing
  - `Dockerfile-stateafl` - Container optimized for StateAFL
  - `ft-*.yaml` - Fuzztruction source/sink configurations
  - `pingu-*.yaml` - Pingu fuzzer configurations
  - `in-tls/` - Initial fuzzing seeds
  - `tls.dict` - TLS protocol dictionary for fuzzing
  - `*.patch` - Fuzzing-specific patches

- **WolfSSL/** - Lightweight TLS library
- **GnuTLS/** - GPL-licensed TLS implementation
- **LibreSSL/** - OpenBSD fork of OpenSSL
- **mbedtls/** - ARM's embedded TLS library

#### 📁 subjects/SSH/ - Secure Shell
- **OpenSSH/** - Standard SSH implementation
- **dropbear/** - Lightweight SSH server
- **libssh/** - Multi-platform SSH library
- **wolfssh/** - WolfSSL's SSH implementation

#### 📁 subjects/QUIC/ - Quick UDP Internet Connections
- **OpenSSL/** - QUIC implementation in OpenSSL 3.0+
- **ngtcp2/** - C implementation
- **quiche/** - Cloudflare's Rust implementation
- **picoquic/** - Minimal C implementation
- **mvfst/** - Facebook's C++ implementation

#### 📁 subjects/DTLS/ - Datagram TLS
- **TinyDTLS/** - Minimal DTLS implementation
- **OpenSSL/** - DTLS in OpenSSL

#### 📁 subjects/MQTT/ - Message Queuing Telemetry Transport
- **mosquitto/** - Popular MQTT broker (baseline plaintext protocol)

#### 📁 subjects/DICOM/ - Medical Imaging
- **dcmtk/** - DICOM toolkit (baseline plaintext protocol)

#### 📁 subjects/RTSP/ - Real-Time Streaming Protocol
- **Live555/** - Streaming media library (baseline plaintext protocol)

### 📁 scripts/ - Core Automation
- **build-env.sh** - Builds fuzzer environment Docker images
  - Supports: aflnet, stateafl, sgfuzz, ft, puffin, pingu
  - Handles proxy configuration and mirrors

- **build.sh** - Builds target-specific fuzzing images
  - Creates images like: `pingu-aflnet-tls-openssl:latest`
  - Parameters: `-t TARGET -f FUZZER -v VERSION`

- **run.sh** - Executes fuzzing campaigns
  - Manages container lifecycle and CPU affinity
  - Parameters: `--times N --timeout SECONDS -o OUTPUT_DIR`
  - Supports parallel execution with automatic CPU scheduling

- **evaluate.sh** - Results analysis and visualization
  - Generates coverage plots and statistical summaries
  - Launches Jupyter Lab at localhost:38888

- **dev.sh** - Development environment launcher
  - Provides interactive container with all fuzzing tools

- **utils.sh** - Shared utility functions
  - Logging, argument parsing, coverage computation
  - CPU load monitoring and port checking

- **dispatch.sh** - Internal container orchestration
  - Called by run.sh to manage fuzzing inside containers

- **idle_cpu.py** - CPU core selection for parallel runs

### 📁 scripts/dockerfile/ - Container Definitions
- **Dockerfile-env-*** - Base environments for each fuzzer
- **Dockerfile** - Runtime container template
- **Dockerfile-eval** - Analysis environment with Jupyter

### 📁 scripts/analysis/ - Coverage Analysis
- **coverage_plotting.py** - Generate coverage over time graphs
- **profuzzbench_*.sh** - Batch processing scripts
- **evaluation/** - Statistical analysis tools
  - `plot.py` - Coverage visualization
  - `summary.py` - Statistical summaries

### 📁 scripts/execution/ - Batch Operations
- **profuzzbench_build_all.sh** - Build all targets
- **profuzzbench_exec_all.sh** - Execute all fuzzing campaigns
- **profuzzbench_exec_common.sh** - Common execution utilities

### 📁 patches/ - Fuzzer-Specific Patches
- **aflnet.patch** - AFLNet integration patches
- **stateafl.patch** - StateAFL modifications
- **sgfuzz.patch** - SGFuzz support
- **ft.patch** - Fuzztruction patches
- **tlsh.patch** - TLSH fuzzy hashing support

### 📁 output/ - Fuzzing Results
Structure: `pingu-{fuzzer}-{protocol}-{implementation}-{timestamp}/`
- **0/** - AFLNet/StateAFL queue and findings
- **cov_html/** - HTML coverage reports
- **coverage.csv** - Coverage progression data
- **crashing/** - Crash test cases
- **interesting/** - Interesting test cases
- **fuzzer_stats** - Fuzzer performance metrics
- **plot_data** - Real-time fuzzing statistics

### 📁 subjects/*/config.sh Functions
Each protocol implementation provides these standardized functions:
- `checkout VERSION` - Clone and prepare source code
- `build_{fuzzer}` - Build instrumented binaries
- `run_{fuzzer} TIMEOUT` - Execute fuzzing campaign
- `replay FILE` - Replay test cases for coverage
- `build_gcov` - Build for coverage analysis

## Common Commands Reference

### Environment Setup
```bash
# Build all fuzzer environments
for fuzzer in aflnet stateafl sgfuzz ft pingu; do
    ./scripts/build-env.sh -f $fuzzer
done

# Build specific target
./scripts/build.sh -t TLS/OpenSSL -f stateafl -v 7b649c7
```

### Fuzzing Campaign
```bash
# Single run
./scripts/run.sh -t TLS/OpenSSL -f stateafl -v 7b649c7 --times 1 --timeout 3600 -o output

# Parallel runs with CPU affinity
./scripts/run.sh -t TLS/WolfSSL -f sgfuzz -v v5.6.6-stable --times 8 --timeout 86400 -o output

# Development/debug mode
./scripts/dev.sh -f ft
```

### Results Analysis
```bash
# Generate coverage plot
./scripts/evaluate.sh -t TLS/OpenSSL -f stateafl -v 7b649c7 -o output -c 4

# Statistical summary
./scripts/evaluate.sh -t TLS/OpenSSL -f stateafl -v 7b649c7 -o output -c 4 --summary

# Jupyter analysis
./scripts/evaluate.sh  # then open http://localhost:38888
```

## Configuration Templates

### Protocol-Specific Configurations
Each protocol provides standardized configuration templates:
- `ft-source.yaml` - Fuzztruction generator configuration
- `ft-sink.yaml` - Fuzztruction consumer configuration
- `pingu-source.yaml` - Pingu generator configuration
- `pingu-sink.yaml` - Pingu consumer configuration

### Environment Variables
- `MAKE_OPT="-j$(nproc)"` - Parallel builds
- `HTTP_PROXY`/`HTTPS_PROXY` - Proxy configuration
- `ZH_CN=true` - Chinese mirror usage
- `PREBUILT_ENV_VAR_NAME` - Use prebuilt images

## Important Prerequisites
- Docker with buildkit support
- ASLR disabled: `echo 0 | sudo tee /proc/sys/kernel/randomize_va_space`
- Core dumps enabled: `echo core | sudo tee /proc/sys/kernel/core_pattern`
- Sufficient disk space (>10GB for images + results)