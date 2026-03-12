#!/usr/bin/env bash

function checkout {
    gquiche_baseline="243b50d"
    boringssl_ref="0.20250415.0"
    target_ref="${1:-$gquiche_baseline}"

    if [ -n "${HTTP_PROXY:-}" ]; then
        export http_proxy="${HTTP_PROXY}"
    fi
    if [ -n "${HTTPS_PROXY:-}" ]; then
        export https_proxy="${HTTPS_PROXY}"
    fi
    if [ -n "${ALL_PROXY:-}" ]; then
        export all_proxy="${ALL_PROXY}"
    fi

    mkdir -p repo

    clone_cmd=(git clone https://github.com/google/quiche.git .git-cache/gquiche)
    fetch_cmd=(git fetch --all --tags)

    if [ ! -d ".git-cache/gquiche" ]; then
        if ! "${clone_cmd[@]}"; then
            echo "[!] git clone failed with current proxy env, retrying without proxy"
            env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
                "${clone_cmd[@]}" || return 1
        fi
    else
        pushd .git-cache/gquiche >/dev/null
        if ! "${fetch_cmd[@]}"; then
            echo "[!] git fetch failed with current proxy env, retrying without proxy"
            env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
                "${fetch_cmd[@]}" || return 1
        fi
        popd >/dev/null
    fi

    cp -r .git-cache/gquiche repo/gquiche
    pushd repo/gquiche >/dev/null
    git checkout "${gquiche_baseline}"
    git apply ${HOME}/profuzzbench/subjects/QUIC/gquiche/gquiche-deterministic-random.patch || return 1
    git apply ${HOME}/profuzzbench/subjects/QUIC/gquiche/gquiche-deterministic-time.patch || return 1
    if ! grep -q 'local_path_override(module_name = "boringssl", path = "../boringssl")' MODULE.bazel; then
        cat >>MODULE.bazel <<'EOF'

local_path_override(module_name = "boringssl", path = "../boringssl")
EOF
    fi
    git add .
    git commit -m "apply deterministic random/time patches for gquiche"
    patch_commit=$(git rev-parse HEAD)
    if [ "${target_ref}" != "${gquiche_baseline}" ]; then
        git checkout "${target_ref}"
        git cherry-pick "${patch_commit}" || return 1
    fi
    git submodule update --init --recursive
    popd >/dev/null

    boringssl_archive=".git-cache/boringssl-${boringssl_ref}.tar.gz"
    boringssl_url="https://github.com/google/boringssl/releases/download/${boringssl_ref}/boringssl-${boringssl_ref}.tar.gz"
    if [ ! -f "${boringssl_archive}" ]; then
        mkdir -p .git-cache
        if ! curl -fL "${boringssl_url}" -o "${boringssl_archive}"; then
            echo "[!] boringssl download failed with current proxy env, retrying without proxy"
            env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
                curl -fL "${boringssl_url}" -o "${boringssl_archive}" || return 1
        fi
    fi

    rm -rf repo/boringssl
    tar -xzf "${boringssl_archive}" -C repo
    mv "repo/boringssl-${boringssl_ref}" repo/boringssl
    pushd repo/boringssl >/dev/null
    patch -p1 < ${HOME}/profuzzbench/subjects/QUIC/gquiche/boringssl-deterministic-random.patch || return 1
    popd >/dev/null
}

function _prepare_variant_dir {
    variant=$1
    mkdir -p "target/${variant}"
    rm -rf target/${variant}/*
    cp -r repo/gquiche "target/${variant}/gquiche"
    cp -r repo/boringssl "target/${variant}/boringssl"
}

function _resolve_quic_server {
    root=$1

    candidates=(
        "${root}/bazel-bin/quiche/quic/tools/quic/quic_server"
        "${root}/bazel-bin/quiche/quic/tools/quic/quic_server_/quic_server"
        "${root}/bazel-bin/quiche/quic_server"
    )

    for c in "${candidates[@]}"; do
        if [ -x "$c" ]; then
            echo "$c"
            return 0
        fi
    done

    found=$(find "${root}/bazel-bin" -type f -name quic_server -perm -u+x 2>/dev/null | head -n 1 || true)
    if [ -n "$found" ]; then
        echo "$found"
        return 0
    fi

    return 1
}

function _build_quiche_with_bazel {
    variant_root=$1
    cc_bin=$2
    cxx_bin=$3
    mode=$4

    pushd "${variant_root}" >/dev/null

    export CC="${cc_bin}"
    export CXX="${cxx_bin}"

    common_args=(
        "--repo_env=CC=${cc_bin}"
        "--repo_env=CXX=${cxx_bin}"
        "--action_env=CC=${cc_bin}"
        "--action_env=CXX=${cxx_bin}"
        "--copt=-g"
        "--copt=-O0"
        "--cxxopt=-g"
        "--cxxopt=-O0"
        "--cxxopt=-DNDEBUG"
    )
    coverage_args=()

    case "$mode" in
    asan | aflnet | stateafl)
        common_args+=(
            "--copt=-fsanitize=address"
            "--cxxopt=-fsanitize=address"
            "--linkopt=-fsanitize=address"
        )
        ;;
    gcov)
        # Match ft-net-quicfuzzer style LLVM coverage instrumentation.
        common_args+=(
            "--copt=-fprofile-instr-generate"
            "--cxxopt=-fprofile-instr-generate"
            "--linkopt=-fprofile-instr-generate"
            "--copt=-fcoverage-mapping"
            "--cxxopt=-fcoverage-mapping"
            "--linkopt=-fcoverage-mapping"
        )
        ;;
    *)
        echo "[!] Unknown build mode: ${mode}"
        popd >/dev/null
        return 1
        ;;
    esac

    targets=(
        "//quiche:quic_server"
        "//quiche/quic/tools:quic_server"
        "//quiche/quic/tools/quic:quic_server"
    )

    built_target=""
    for t in "${targets[@]}"; do
        if bazel build "${common_args[@]}" "${coverage_args[@]}" "$t"; then
            built_target="$t"
            break
        fi
    done

    if [ -z "${built_target}" ]; then
        echo "[!] Failed to build quic_server from known Bazel targets"
        popd >/dev/null
        return 1
    fi

    server_bin=$(_resolve_quic_server "${variant_root}" || true)
    if [ -z "${server_bin}" ]; then
        echo "[!] quic_server binary not found after building ${built_target}"
        popd >/dev/null
        return 1
    fi

    popd >/dev/null
}

function _select_llvm_cov_tool {
    for c in llvm-cov-17 llvm-cov; do
        if command -v "${c}" >/dev/null 2>&1; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

function _select_llvm_profdata_tool {
    for c in llvm-profdata-17 llvm-profdata; do
        if command -v "${c}" >/dev/null 2>&1; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

function _llvm_cov_summary_lines {
    profile_raw=$1
    profile_data=$2
    bin_path=$3

    llvm_cov_bin=$(_select_llvm_cov_tool) || return 1
    llvm_profdata_bin=$(_select_llvm_profdata_tool) || return 1

    if [ ! -f "${profile_raw}" ]; then
        echo "lines: 0.0% (0 of 0)"
        echo "branches: 0.0% (0 of 0)"
        return 0
    fi

    "${llvm_profdata_bin}" merge -sparse "${profile_raw}" -o "${profile_data}" >/dev/null 2>&1 || return 1
    "${llvm_cov_bin}" export --summary-only --instr-profile="${profile_data}" "${bin_path}" 2>/dev/null | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("lines: 0.0% (0 of 0)")
    print("branches: 0.0% (0 of 0)")
    raise SystemExit(0)

totals = data.get("data", [{}])[0].get("totals", {})
line = totals.get("lines", {})
branch = totals.get("branches", {})
l_cov = int(line.get("covered", 0) or 0)
l_cnt = int(line.get("count", 0) or 0)
b_cov = int(branch.get("covered", 0) or 0)
b_cnt = int(branch.get("count", 0) or 0)
l_per = (100.0 * l_cov / l_cnt) if l_cnt else 0.0
b_per = (100.0 * b_cov / b_cnt) if b_cnt else 0.0
print(f"lines: {l_per:.1f}% ({l_cov} of {l_cnt})")
print(f"branches: {b_per:.1f}% ({b_cov} of {b_cnt})")
'
}

function _llvm_cov_summary_lines_dir {
    profile_dir=$1
    profile_data=$2
    bin_path=$3

    llvm_cov_bin=$(_select_llvm_cov_tool) || return 1
    llvm_profdata_bin=$(_select_llvm_profdata_tool) || return 1

    raw_list=$(find "${profile_dir}" -maxdepth 1 -type f -name '*.profraw' 2>/dev/null | sort || true)
    if [ -z "${raw_list}" ]; then
        echo "lines: 0.0% (0 of 0)"
        echo "branches: 0.0% (0 of 0)"
        return 0
    fi

    # shellcheck disable=SC2086
    "${llvm_profdata_bin}" merge -sparse ${raw_list} -o "${profile_data}" >/dev/null 2>&1 || return 1
    "${llvm_cov_bin}" export --summary-only --instr-profile="${profile_data}" "${bin_path}" 2>/dev/null | python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("lines: 0.0% (0 of 0)")
    print("branches: 0.0% (0 of 0)")
    raise SystemExit(0)

totals = data.get("data", [{}])[0].get("totals", {})
line = totals.get("lines", {})
branch = totals.get("branches", {})
l_cov = int(line.get("covered", 0) or 0)
l_cnt = int(line.get("count", 0) or 0)
b_cov = int(branch.get("covered", 0) or 0)
b_cnt = int(branch.get("count", 0) or 0)
l_per = (100.0 * l_cov / l_cnt) if l_cnt else 0.0
b_per = (100.0 * b_cov / b_cnt) if b_cnt else 0.0
print(f"lines: {l_per:.1f}% ({l_cov} of {l_cnt})")
print(f"branches: {b_per:.1f}% ({b_cov} of {b_cnt})")
'
}

function _prepare_quic_response_cache {
    cache_dir=$1
    mkdir -p "${cache_dir}"
    if [ ! -f "${cache_dir}/index.html" ]; then
        echo "ok" > "${cache_dir}/index.html"
    fi
}

function replay {
    cert_dir=${HOME}/profuzzbench/cert
    cache_dir=${PWD}/quic_response_cache
    fake_time_value="${FAKE_TIME:-2026-03-11 12:00:00}"
    _prepare_quic_response_cache "${cache_dir}"

    server_bin=$(_resolve_quic_server "${PWD}" || true)
    if [ -z "${server_bin}" ]; then
        echo "[!] replay failed: quic_server binary not found"
        return 1
    fi

    profile_dir="${PWD}/coverage-profraw"
    mkdir -p "${profile_dir}"
    case_tag=$(basename "$1" | tr -c 'A-Za-z0-9._-' '_')

    LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${fake_time_value}" \
        LLVM_PROFILE_FILE="${profile_dir}/${case_tag}.profraw" \
        "${server_bin}" \
        --quic_response_cache_dir="${cache_dir}" \
        --certificate_file="${cert_dir}/fullchain.crt" \
        --key_file="${cert_dir}/server.key" \
        --port=4433 >/tmp/quic-server-replay.log 2>&1 &
    server_pid=$!

    sleep 1
    timeout -s INT -k 1s 5s "${HOME}/aflnet/aflnet-replay" "$1" NOP 4433 100 || true
    kill -INT "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" || true
}

function build_aflnet {
    _prepare_variant_dir "aflnet"
    pushd "${HOME}/target/aflnet/gquiche" >/dev/null
    export AFL_USE_ASAN=1
    _build_quiche_with_bazel "${PWD}" "${HOME}/aflnet/afl-clang-fast" "${HOME}/aflnet/afl-clang-fast++" "aflnet"
    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    if [ "${3:-}" = "--" ]; then
        replay_step=${4:-$1}
        gcov_step=${5:-$2}
        timeout=${6:-300s}
    fi
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/QUIC/gquiche/in-quic
    cert_dir=${HOME}/profuzzbench/cert

    if [ ! -d "${indir}" ]; then
        indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/ngtcp2-seed-replay
    fi

    pushd "${HOME}/target/aflnet/gquiche" >/dev/null
    mkdir -p "${outdir}"

    cache_dir=${PWD}/quic_response_cache
    _prepare_quic_response_cache "${cache_dir}"
    server_bin=$(_resolve_quic_server "${PWD}" || true)
    if [ -z "${server_bin}" ]; then
        echo "[!] run_aflnet failed: quic_server binary not found"
        popd >/dev/null
        return 1
    fi

    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    unset AFL_PRELOAD
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -s INT -k 1s --preserve-status "${timeout}" \
        "${HOME}/aflnet/afl-fuzz" \
        -d -i "${indir}" -o "${outdir}" -N "udp://127.0.0.1/4433 " \
        -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
        -- \
        "${server_bin}" \
        --quic_response_cache_dir="${cache_dir}" \
        --certificate_file="${cert_dir}/fullchain.crt" \
        --key_file="${cert_dir}/server.key" \
        --port=4433 || true

    cd "${HOME}/target/gcov/gquiche"
    if ! _select_llvm_cov_tool >/dev/null 2>&1 || ! _select_llvm_profdata_tool >/dev/null 2>&1; then
        echo "[!] run_aflnet failed: llvm-cov/llvm-profdata not found"
        popd >/dev/null
        return 1
    fi
    coverage_bin=$(_resolve_quic_server "${PWD}" || true)
    if [ -z "${coverage_bin}" ]; then
        echo "[!] run_aflnet failed: coverage quic_server binary not found in ${PWD}/bazel-bin"
        popd >/dev/null
        return 1
    fi
    # Reset profiling artifacts once, then keep accumulating across replays.
    rm -rf coverage-profraw
    rm -f coverage.profdata || true
    cov_cmd="_llvm_cov_summary_lines_dir \"${PWD}/coverage-profraw\" \"${PWD}/coverage.profdata\" \"${coverage_bin}\""
    list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    compute_coverage replay "$list_cmd" "${gcov_step}" "${outdir}/coverage.csv" "$cov_cmd"

    popd >/dev/null
}

function build_stateafl {
    _prepare_variant_dir "stateafl"
    pushd "${HOME}/target/stateafl/gquiche" >/dev/null
    export AFL_USE_ASAN=1
    _build_quiche_with_bazel "${PWD}" "${HOME}/stateafl/afl-clang-fast" "${HOME}/stateafl/afl-clang-fast++" "stateafl"
    popd >/dev/null
}

function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    if [ "${3:-}" = "--" ]; then
        replay_step=${4:-$1}
        gcov_step=${5:-$2}
        timeout=${6:-300s}
    fi
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/QUIC/gquiche/in-quic
    cert_dir=${HOME}/profuzzbench/cert

    if [ ! -d "${indir}" ]; then
        indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/ngtcp2-seed-replay
    fi

    pushd "${HOME}/target/stateafl/gquiche" >/dev/null
    mkdir -p "${outdir}"

    cache_dir=${PWD}/quic_response_cache
    _prepare_quic_response_cache "${cache_dir}"
    server_bin=$(_resolve_quic_server "${PWD}" || true)
    if [ -z "${server_bin}" ]; then
        echo "[!] run_stateafl failed: quic_server binary not found"
        popd >/dev/null
        return 1
    fi

    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    unset AFL_PRELOAD
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -s INT -k 1s --preserve-status "${timeout}" \
        "${HOME}/stateafl/afl-fuzz" \
        -d -i "${indir}" -o "${outdir}" -N "udp://127.0.0.1/4433 " \
        -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
        -- \
        "${server_bin}" \
        --quic_response_cache_dir="${cache_dir}" \
        --certificate_file="${cert_dir}/fullchain.crt" \
        --key_file="${cert_dir}/server.key" \
        --port=4433 || true

    cd "${HOME}/target/gcov/gquiche"
    if ! _select_llvm_cov_tool >/dev/null 2>&1 || ! _select_llvm_profdata_tool >/dev/null 2>&1; then
        echo "[!] run_stateafl failed: llvm-cov/llvm-profdata not found"
        popd >/dev/null
        return 1
    fi
    coverage_bin=$(_resolve_quic_server "${PWD}" || true)
    if [ -z "${coverage_bin}" ]; then
        echo "[!] run_stateafl failed: coverage quic_server binary not found in ${PWD}/bazel-bin"
        popd >/dev/null
        return 1
    fi
    rm -rf coverage-profraw
    rm -f coverage.profdata || true
    cov_cmd="_llvm_cov_summary_lines_dir \"${PWD}/coverage-profraw\" \"${PWD}/coverage.profdata\" \"${coverage_bin}\""
    list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    compute_coverage replay "$list_cmd" "${gcov_step}" "${outdir}/coverage.csv" "$cov_cmd"

    popd >/dev/null
}

function build_sgfuzz {
    echo "Not implemented"
}

function run_sgfuzz {
    echo "Not implemented"
}

function build_ft_generator {
    echo "Not implemented"
}

function build_ft_consumer {
    echo "Not implemented"
}

function run_ft {
    echo "Not implemented"
}

function build_quicfuzz {
    echo "Not implemented"
}

function run_quicfuzz {
    echo "Not implemented"
}

function build_asan {
    _prepare_variant_dir "asan"
    pushd "${HOME}/target/asan/gquiche" >/dev/null
    _build_quiche_with_bazel "${PWD}" "clang" "clang++" "asan"
    popd >/dev/null
}

function build_gcov {
    _prepare_variant_dir "gcov"
    pushd "${HOME}/target/gcov/gquiche" >/dev/null
    _build_quiche_with_bazel "${PWD}" "clang" "clang++" "gcov"
    popd >/dev/null
}

function install_dependencies {
    export DEBIAN_FRONTEND=noninteractive
    # Ubuntu lunar is EOL; switch apt sources to old-releases to keep builds reproducible.
    if [ -f /etc/apt/sources.list ]; then
        sudo sed -i \
            -e 's#http://mirrors.ustc.edu.cn/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' \
            -e 's#http://archive.ubuntu.com/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' \
            -e 's#http://security.ubuntu.com/ubuntu#http://old-releases.ubuntu.com/ubuntu#g' \
            /etc/apt/sources.list || true
    fi
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        libev-dev
    if ! command -v bazel >/dev/null 2>&1; then
        tmp_bazelisk="$(mktemp)"
        if curl -fsSL \
            https://github.com/bazelbuild/bazelisk/releases/download/v1.20.0/bazelisk-linux-amd64 \
            -o "${tmp_bazelisk}"; then
            sudo install -m 0755 "${tmp_bazelisk}" /usr/local/bin/bazel
        else
            sudo apt-get install -y --no-install-recommends bazel-bootstrap || true
            if command -v bazel-bootstrap >/dev/null 2>&1; then
                sudo ln -sf "$(command -v bazel-bootstrap)" /usr/local/bin/bazel
            fi
        fi
        rm -f "${tmp_bazelisk}"
        if ! command -v bazel >/dev/null 2>&1; then
            echo "[!] bazel is not available"
            return 1
        fi
    fi
    sudo rm -rf /var/lib/apt/lists/*
}
