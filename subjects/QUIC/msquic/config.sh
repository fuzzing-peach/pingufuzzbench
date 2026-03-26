#!/usr/bin/env bash

if [ -z "${MAKE_OPT+x}" ] || [ -z "${MAKE_OPT}" ]; then
    MAKE_OPT="-j$(nproc)"
fi

MSQUIC_BASELINE_TAG="v2.5.7-rc"
MSQUIC_FUZZ_PORT="${MSQUIC_FUZZ_PORT:-4567}"
MSQUIC_SUBJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PFB_ROOT_DIR="$(cd "${MSQUIC_SUBJECT_DIR}/../../.." && pwd)"

function _target_root {
    echo "${HOME}/target"
}

function git_clone_retry {
    local url="$1"
    local dst="$2"
    local retries="${3:-3}"
    local recursive="${4:-0}"
    local i=1
    while [ "${i}" -le "${retries}" ]; do
        rm -rf "${dst}"
        if [ "${recursive}" = "1" ]; then
            if git clone --filter=blob:none --recursive "${url}" "${dst}"; then
                return 0
            fi
        else
            if git clone --filter=blob:none "${url}" "${dst}"; then
                return 0
            fi
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

function _maybe_apply_patch {
    local patch_file="$1"
    if [ ! -f "${patch_file}" ]; then
        return 0
    fi
    if git apply --check "${patch_file}" >/dev/null 2>&1; then
        git apply "${patch_file}" || return 1
    fi
    return 0
}

function _resolve_quicsample {
    local root="$1"
    local candidates="
${root}/bin/Release/quicsample
${root}/build/bin/Release/quicsample
${root}/artifacts/bin/linux/x64_Release_openssl/quicsample
"
    local p
    while read -r p; do
        [ -z "${p}" ] && continue
        if [ -x "${p}" ]; then
            echo "${p}"
            return 0
        fi
    done <<< "${candidates}"
    p=$(find "${root}" -type f -name quicsample 2>/dev/null | head -n 1 || true)
    if [ -n "${p}" ]; then
        echo "${p}"
        return 0
    fi
    return 1
}

function _checkout_msquic {
    local target_ref="${1:-${MSQUIC_BASELINE_TAG}}"
    mkdir -p .git-cache repo
    if [ ! -d ".git-cache/msquic/.git" ]; then
        git_clone_retry https://github.com/microsoft/msquic.git .git-cache/msquic 3 0 || return 1
    else
        pushd .git-cache/msquic >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi

    rm -rf repo/msquic
    cp -r .git-cache/msquic repo/msquic
    pushd repo/msquic >/dev/null
    git checkout "${target_ref}" || return 1
    git submodule sync --recursive
    git submodule update --init --recursive --depth 1 submodules/quictls submodules/clog || return 1
    _maybe_apply_patch "${MSQUIC_SUBJECT_DIR}/msquic-random.patch" || return 1
    _maybe_apply_patch "${MSQUIC_SUBJECT_DIR}/msquic-time.patch" || return 1
    _maybe_apply_patch "${MSQUIC_SUBJECT_DIR}/msquic-no-blocking-getchar.patch" || return 1
    popd >/dev/null
}

function _checkout_ngtcp2_stack {
    mkdir -p .git-cache repo

    if [ ! -d ".git-cache/ngtcp2/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/ngtcp2 .git-cache/ngtcp2 3 1 || return 1
    else
        pushd .git-cache/ngtcp2 >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/ngtcp2
    cp -r .git-cache/ngtcp2 repo/ngtcp2
    pushd repo/ngtcp2 >/dev/null
    git checkout 28d3126 || return 1
    popd >/dev/null

    if [ ! -d ".git-cache/wolfssl/.git" ]; then
        git_clone_retry https://github.com/wolfSSL/wolfssl .git-cache/wolfssl || return 1
    else
        pushd .git-cache/wolfssl >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/wolfssl
    cp -r .git-cache/wolfssl repo/wolfssl
    pushd repo/wolfssl >/dev/null
    git checkout b3f08f3 || return 1
    _maybe_apply_patch "${PFB_ROOT_DIR}/subjects/QUIC/ngtcp2/wolfssl-random.patch" || true
    _maybe_apply_patch "${PFB_ROOT_DIR}/subjects/QUIC/ngtcp2/wolfssl-time.patch" || true
    popd >/dev/null

    if [ ! -d ".git-cache/nghttp3/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/nghttp3 .git-cache/nghttp3 3 1 || return 1
    else
        pushd .git-cache/nghttp3 >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/nghttp3
    cp -r .git-cache/nghttp3 repo/nghttp3
    pushd repo/nghttp3 >/dev/null
    git checkout 21526d7 || return 1
    git submodule update --init --recursive
    popd >/dev/null
}

function checkout {
    local target_ref="${1:-${MSQUIC_BASELINE_TAG}}"
    _checkout_msquic "${target_ref}" || return 1
    _checkout_ngtcp2_stack || return 1
}

function _run_msquic_server_for_replay {
    local bin_path="$1"
    local replay_file="$2"
    local cert_dir="${HOME}/profuzzbench/cert"
    local fake_time_value="${FAKE_TIME:-2026-02-01 12:00:00}"

    LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${fake_time_value}" \
        "${bin_path}" \
        -server \
        -cert_file:${cert_dir}/fullchain.crt \
        -key_file:${cert_dir}/server.key \
        -listen:0.0.0.0 \
        -port:${MSQUIC_FUZZ_PORT} >/tmp/msquic-replay.log 2>&1 &
    local server_pid=$!

    sleep 1
    timeout -s INT -k 1s 5s "${HOME}/aflnet/aflnet-replay" "${replay_file}" NOP "${MSQUIC_FUZZ_PORT}" 100 || true
    kill -INT "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" 2>/dev/null || true
}

function replay {
    local target_root
    target_root=$(_target_root)

    local gcov_bin
    gcov_bin=$(_resolve_quicsample "${target_root}/gcov/msquic/build" || true)
    if [ -z "${gcov_bin}" ]; then
        gcov_bin=$(_resolve_quicsample "${target_root}/gcov/msquic" || true)
    fi
    if [ -z "${gcov_bin}" ]; then
        echo "[!] replay failed: gcov quicsample not found under ${target_root}/gcov/msquic"
        return 1
    fi

    _run_msquic_server_for_replay "${gcov_bin}" "$1"
}

function _configure_and_build_msquic {
    local cc="$1"
    local cxx="$2"
    local cflags="$3"
    local cxxflags="$4"
    local ldflags="$5"
    local src_dir="$6"
    local build_dir="$7"

    mkdir -p "${build_dir}"
    pushd "${build_dir}" >/dev/null

    export CC="${cc}"
    export CXX="${cxx}"
    export CFLAGS="${cflags}"
    export CXXFLAGS="${cxxflags}"
    export LDFLAGS="${ldflags}"

    cmake -G "Unix Makefiles" \
        -DQUIC_BUILD_TOOLS=ON \
        -DQUIC_BUILD_SHARED=OFF \
        -DQUIC_BUILD_TEST=OFF \
        -DQUIC_BUILD_PERF=OFF \
        -DQUIC_TLS_LIB=quictls \
        -DCMAKE_BUILD_TYPE=Debug \
        "${src_dir}" || return 1
    cmake --build . --target quicsample ${MAKE_OPT} || return 1

    popd >/dev/null
}

function _ensure_msquic_repo {
    if [ ! -d "repo/msquic/.git" ]; then
        _checkout_msquic "${MSQUIC_BASELINE_TAG}" || return 1
    fi
}

function build_aflnet {
    _ensure_msquic_repo || return 1

    local target_root
    target_root=$(_target_root)
    local afl_cc="${HOME}/aflnet/afl-clang-fast"
    local afl_cxx="${HOME}/aflnet/afl-clang-fast++"
    if [ ! -x "${afl_cc}" ] || [ ! -x "${afl_cxx}" ]; then
        echo "[!] build_aflnet failed: missing ${afl_cc} or ${afl_cxx}"
        return 1
    fi
    echo "[+] build_aflnet compiler: CC=${afl_cc} CXX=${afl_cxx}"

    mkdir -p "${target_root}/aflnet"
    rm -rf "${target_root}/aflnet"/*
    cp -r repo/msquic "${target_root}/aflnet/msquic"

    _configure_and_build_msquic \
        "${afl_cc}" \
        "${afl_cxx}" \
        "-g -O2 -fsanitize=address" \
        "-g -O2 -fsanitize=address" \
        "-fsanitize=address" \
        "${target_root}/aflnet/msquic" \
        "${target_root}/aflnet/msquic/build" || return 1

    local bin
    bin=$(_resolve_quicsample "${target_root}/aflnet/msquic/build" || true)
    if [ -z "${bin}" ]; then
        echo "[!] build_aflnet failed: quicsample not found"
        return 1
    fi
}

function run_aflnet {
    local replay_step="${1:-1}"
    local gcov_step="${2:-1}"
    local timeout="${3:-300}"

    local target_root
    target_root=$(_target_root)
    local outdir=/tmp/fuzzing-output
    local indir="${HOME}/profuzzbench/subjects/QUIC/msquic/seed"
    local cert_dir="${HOME}/profuzzbench/cert"

    if [ ! -d "${indir}" ]; then
        echo "[!] run_aflnet failed: missing seed directory ${indir}"
        return 1
    fi

    local build_dir="${target_root}/aflnet/msquic/build"
    local server_bin
    server_bin=$(_resolve_quicsample "${build_dir}" || true)
    if [ -z "${server_bin}" ]; then
        echo "[!] run_aflnet failed: quicsample not found in ${build_dir}"
        return 1
    fi

    mkdir -p "${outdir}"
    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-02-01 12:00:00}"
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -s INT -k 1s --preserve-status "${timeout}" \
        "${HOME}/aflnet/afl-fuzz" \
        -d -i "${indir}" -o "${outdir}" -N "udp://127.0.0.1/${MSQUIC_FUZZ_PORT} " \
        -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
        -- \
        "${server_bin}" \
        -server \
        -cert_file:${cert_dir}/fullchain.crt \
        -key_file:${cert_dir}/server.key \
        -listen:0.0.0.0 \
        -port:${MSQUIC_FUZZ_PORT} || true

    pushd "${target_root}/gcov/msquic/build" >/dev/null
    local gcov_exec="gcov"
    local sample_gcno
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)
    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        gcov_exec="llvm-cov-17 gcov"
    fi

    local gcov_common_opts="--gcov-executable \"${gcov_exec}\" --gcov-ignore-parse-errors=negative_hits.warn_once_per_file -r ${target_root}/gcov/msquic"
    eval "gcovr ${gcov_common_opts} -s -d" >/dev/null 2>&1 || true

    local list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    local cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    compute_coverage replay "$list_cmd" "${gcov_step}" "${outdir}/coverage.csv" "$cov_cmd" ""

    mkdir -p "${outdir}/cov_html"
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true
    popd >/dev/null
}

function build_sgfuzz {
    _ensure_msquic_repo || return 1

    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/msquic target/sgfuzz/msquic

    pushd target/sgfuzz/msquic >/dev/null
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -Wno-int-conversion"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -Wno-int-conversion"
    export LDFLAGS=""

    python3 "${HOME}/sgfuzz/sanitizer/State_machine_instrument.py" .
    _configure_and_build_msquic "${CC}" "${CXX}" "${CFLAGS}" "${CXXFLAGS}" "${LDFLAGS}" "${PWD}" "${PWD}/build" || return 1

    local build_dir="${PWD}/build"
    local bin
    bin=$(_resolve_quicsample "${build_dir}" || true)
    if [ -z "${bin}" ]; then
        echo "[!] build_sgfuzz failed: quicsample not found after CMake build"
        popd >/dev/null
        return 1
    fi

    pushd "$(dirname "${bin}")" >/dev/null
    extract-bc ./quicsample || return 1

    cat > hf_udp_addr.c <<EOF2
#include <arpa/inet.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>

socklen_t HonggfuzzNetDriverServerAddress(
    struct sockaddr_storage *addr,
    int *type,
    int *protocol) {
    struct sockaddr_in *in = (struct sockaddr_in *)addr;
    memset(addr, 0, sizeof(*addr));
    in->sin_family = AF_INET;
    in->sin_port = htons(${MSQUIC_FUZZ_PORT});
    in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    *type = SOCK_DGRAM;
    *protocol = IPPROTO_UDP;
    return (socklen_t)sizeof(*in);
}
EOF2

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE="${HOME}/target/sgfuzz/msquic/enum_types.txt"
    opt -load-pass-plugin="${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so" \
        -passes="sgfuzz-source" -debug-pass-manager quicsample.bc -o quicsample_opt.bc || return 1
    (llvm-dis-17 quicsample_opt.bc -o quicsample_opt.ll || llvm-dis quicsample_opt.bc -o quicsample_opt.ll) || return 1
    sed -i 's/optnone //g;s/optnone//g' quicsample_opt.ll

    local msquic_a
    local platform_a
    local ssl_a
    local crypto_a
    msquic_a=$(find "${build_dir}" -type f -name "libmsquic.a" | head -n 1 || true)
    platform_a=$(find "${build_dir}" -type f -name "libmsquic_platform.a" | head -n 1 || true)
    if [ -z "${platform_a}" ]; then
        platform_a=$(find "${build_dir}" -type f -name "libplatform.a" | head -n 1 || true)
    fi
    ssl_a=$(find "${build_dir}" -type f -name "libssl.a" | head -n 1 || true)
    crypto_a=$(find "${build_dir}" -type f -name "libcrypto.a" | head -n 1 || true)
    if [ -z "${msquic_a}" ] || [ -z "${platform_a}" ] || [ -z "${ssl_a}" ] || [ -z "${crypto_a}" ]; then
        echo "[!] build_sgfuzz failed: required static objects/libs not found"
        popd >/dev/null
        popd >/dev/null
        return 1
    fi

    clang quicsample_opt.ll hf_udp_addr.c -o quicsample \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DSGFUZZ \
        "${msquic_a}" \
        "${platform_a}" \
        "${ssl_a}" \
        "${crypto_a}" \
        -ldl -latomic -lnuma -lpthread -lrt -lm -lresolv \
        -lsFuzzer -lhfnetdriver -lhfcommon -lstdc++

    popd >/dev/null
    popd >/dev/null
}

function run_sgfuzz {
    local replay_step="${1:-1}"
    local gcov_step="${2:-1}"
    local timeout="${3:-300}"

    local target_root
    target_root=$(_target_root)
    local outdir=/tmp/fuzzing-output
    local queue="${outdir}/replayable-queue"
    local indir="${HOME}/profuzzbench/subjects/QUIC/msquic/seed"
    local cert_dir="${HOME}/profuzzbench/cert"

    if [ ! -d "${indir}" ]; then
        echo "[!] run_sgfuzz failed: missing seed directory ${indir}"
        return 1
    fi

    local build_dir="${target_root}/sgfuzz/msquic/build"
    local fuzz_bin
    fuzz_bin=$(_resolve_quicsample "${build_dir}" || true)
    if [ -z "${fuzz_bin}" ]; then
        echo "[!] run_sgfuzz failed: quicsample not found in ${build_dir}"
        return 1
    fi

    pushd "$(dirname "${fuzz_bin}")" >/dev/null
    mkdir -p "${queue}" "${outdir}/crashes"
    rm -rf "${queue}"/* "${outdir}/crashes/"*

    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-02-01 12:00:00}"
    export HFND_TESTCASE_BUDGET_MS="${HFND_TESTCASE_BUDGET_MS:-50}"
    export HFND_TCP_PORT="${MSQUIC_FUZZ_PORT}"
    export HFND_FORK_MODE=1

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -fork=1
        -ignore_crashes=1
        -shrink=0
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time=${timeout}
        -artifact_prefix="${outdir}/crashes/"
        "${queue}"
        "${indir}"
    )

    ./quicsample "${SGFuzz_ARGS[@]}" -- \
        -server \
        -cert_file:${cert_dir}/fullchain.crt \
        -key_file:${cert_dir}/server.key || true

    python3 "${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py" "${queue}"

    cd "${target_root}/gcov/msquic/build"
    function replay_sgfuzz_one {
        local gcov_bin
        local cert_dir="${HOME}/profuzzbench/cert"
        local fake_time_value="${FAKE_TIME:-2026-02-01 12:00:00}"
        gcov_bin=$(_resolve_quicsample "${target_root}/gcov/msquic/build" || true)
        if [ -z "${gcov_bin}" ]; then
            return 1
        fi

        LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${fake_time_value}" \
            "${gcov_bin}" \
            -server \
            -cert_file:${cert_dir}/fullchain.crt \
            -key_file:${cert_dir}/server.key >/tmp/msquic-replay.log 2>&1 &
        local server_pid=$!

        sleep 1
        timeout -s INT -k 1s 5s "${HOME}/aflnet/afl-replay" "$1" NOP "${MSQUIC_FUZZ_PORT}" 100 || true
        kill -INT "${server_pid}" >/dev/null 2>&1 || true
        wait "${server_pid}" 2>/dev/null || true
    }

    local gcov_exec="gcov"
    local sample_gcno
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)
    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        gcov_exec="llvm-cov-17 gcov"
    fi

    local gcov_common_opts="--gcov-executable \"${gcov_exec}\" --gcov-ignore-parse-errors=negative_hits.warn_once_per_file -r ${target_root}/gcov/msquic"
    local cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    local list_cmd="find ${queue} -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"

    local seed_replay_file
    seed_replay_file=$(find "${indir}" -maxdepth 1 -type f | sort | head -n 1 || true)
    if [ -n "${seed_replay_file}" ]; then
        echo "[*] run_sgfuzz: replay seed first: ${seed_replay_file}"
        replay_sgfuzz_one "${seed_replay_file}" || true
    fi

    compute_coverage replay_sgfuzz_one "${list_cmd}" "${gcov_step}" "${outdir}/coverage.csv" "${cov_cmd}" ""

    mkdir -p "${outdir}/cov_html"
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true
    popd >/dev/null
}

function build_ft_generator {
    _ensure_msquic_repo || return 1

    local target_root
    target_root=$(_target_root)
    mkdir -p "${target_root}/ft/generator"
    rm -rf "${target_root}/ft/generator"/*
    cp -r repo/msquic "${target_root}/ft/generator/msquic"

    pushd "${target_root}/ft/generator/msquic" >/dev/null
    export FT_CALL_INJECTION=0
    export FT_HOOK_INS=branch
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"
    export LD_LIBRARY_PATH="${HOME}/fuzztruction-net/target/release:${LD_LIBRARY_PATH:-}"

    _configure_and_build_msquic \
        "${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast" \
        "${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++" \
        "-O3 -g -DFT_FUZZING -DFT_GENERATOR" \
        "-O3 -g -DFT_FUZZING -DFT_GENERATOR" \
        "" \
        "${target_root}/ft/generator/msquic" \
        "${target_root}/ft/generator/msquic/build" || return 1

    local gen_bin
    gen_bin=$(_resolve_quicsample "${target_root}/ft/generator/msquic/build" || true)
    if [ -z "${gen_bin}" ]; then
        echo "[!] build_ft_generator failed: quicsample not found under ${target_root}/ft/generator/msquic/build"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
}

function build_ft_consumer {
    _ensure_msquic_repo || return 1
    local target_root
    target_root=$(_target_root)

    mkdir -p "${target_root}/ft/consumer"
    rm -rf "${target_root}/ft/consumer"/*
    cp -r repo/msquic "${target_root}/ft/consumer/msquic"

    local afl_path="${HOME}/fuzztruction-net/consumer/aflpp-consumer"
    _configure_and_build_msquic \
        "${afl_path}/afl-clang-fast" \
        "${afl_path}/afl-clang-fast++" \
        "-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER" \
        "-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER" \
        "-fsanitize=address" \
        "${target_root}/ft/consumer/msquic" \
        "${target_root}/ft/consumer/msquic/build" || return 1
}

function _build_pingu_msquic_variant {
    local variant="$1"
    local role="$2"
    local ins_list="$3"
    local pass_pipeline="$4"
    local patchpoint_blacklist="$5"

    _ensure_msquic_repo || return 1

    local target_root
    target_root=$(_target_root)
    local variant_root="${target_root}/pingu/${variant}"
    local msquic_dir="${variant_root}/msquic"
    local build_dir="${msquic_dir}/build"

    mkdir -p "${variant_root}"
    cp -r repo/msquic "${msquic_dir}"

    pushd "${msquic_dir}" >/dev/null
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export LDFLAGS=""

    _configure_and_build_msquic "${CC}" "${CXX}" "${CFLAGS}" "${CXXFLAGS}" "${LDFLAGS}" "${msquic_dir}" "${build_dir}" || return 1

    local bin
    bin=$(_resolve_quicsample "${build_dir}" || true)
    if [ -z "${bin}" ]; then
        echo "[!] build_pingu_${variant} failed: quicsample not found"
        popd >/dev/null
        return 1
    fi

    pushd "$(dirname "${bin}")" >/dev/null
    extract-bc ./quicsample || return 1

    local src_root_dir="${variant_root}/msquic"

    opt \
        -load-pass-plugin="${HOME}/pingu/pingu-agent/pass/build/pingu-source-pass.so" \
        -load-pass-plugin="${HOME}/pingu/pingu-agent/pass/build/afl-llvm-pass.so" \
        -passes="${pass_pipeline}" \
        -src-root-dir="${src_root_dir}" \
        -ins="${ins_list}" \
        -role="${role}" \
        -patchpoint-blacklist="${patchpoint_blacklist}" \
        quicsample.bc -o quicsample_opt.bc || return 1

    llvm-dis quicsample_opt.bc -o quicsample_opt.ll || return 1
    sed -i 's/optnone //g;s/optnone//g' quicsample_opt.ll

    local msquic_a
    local platform_a
    local ssl_a
    local crypto_a
    msquic_a=$(find "${build_dir}" -type f -name "libmsquic.a" | head -n 1 || true)
    platform_a=$(find "${build_dir}" -type f -name "libmsquic_platform.a" | head -n 1 || true)
    if [ -z "${platform_a}" ]; then
        platform_a=$(find "${build_dir}" -type f -name "libplatform.a" | head -n 1 || true)
    fi
    ssl_a=$(find "${build_dir}" -type f -name "libssl.a" | head -n 1 || true)
    crypto_a=$(find "${build_dir}" -type f -name "libcrypto.a" | head -n 1 || true)
    if [ -z "${msquic_a}" ] || [ -z "${platform_a}" ] || [ -z "${ssl_a}" ] || [ -z "${crypto_a}" ]; then
        echo "[!] build_pingu_${variant} failed: required static libs not found"
        popd >/dev/null
        popd >/dev/null
        return 1
    fi

    clang quicsample_opt.ll -o quicsample \
        -L"${HOME}/pingu/target/release" \
        -Wl,-rpath,"${HOME}/pingu/target/release" \
        -lpingu_agent \
        -fsanitize=address \
        "${msquic_a}" \
        "${platform_a}" \
        "${ssl_a}" \
        "${crypto_a}" \
        -ldl -latomic -lnuma -lpthread -lrt -lm -lresolv -lstdc++ || return 1

    popd >/dev/null
    popd >/dev/null
}

function build_pingu_generator {
    rm -rf "${HOME}/target/pingu/generator/msquic"
    _build_pingu_msquic_variant \
        "generator" \
        "source" \
        "load,store,call,memcpy,trampoline,ret,icmp,memcmp" \
        "pingu-source" \
        "submodules/quictls/crypto,submodules/quictls/include/crypto"
}

function build_pingu_consumer {
    rm -rf "${HOME}/target/pingu/consumer/msquic"
    _build_pingu_msquic_variant \
        "consumer" \
        "sink" \
        "load,store,call,memcpy,trampoline,ret,icmp,memcmp" \
        "pingu-source,afl-coverage" \
        "submodules/quictls/crypto,submodules/quictls/include/crypto"
}

function run_pingu {
    local timeout
    if [[ "${1:-}" =~ ^[0-9]+$ ]] && [[ "${2:-}" =~ ^[0-9]+$ ]] && [[ "${3:-}" =~ ^[0-9]+$ ]]; then
        timeout="$3"
    else
        timeout="${1:-300}"
    fi

    local pingu_bin="${HOME}/pingu/target/debug/pingu"
    if [ ! -x "${pingu_bin}" ]; then
        pingu_bin="${HOME}/pingu/target/release/pingu"
    fi

    local pingu_yaml="${MSQUIC_SUBJECT_DIR}/pingu.yaml"
    if [ ! -f "${pingu_yaml}" ]; then
        echo "[!] run_pingu failed: missing ${MSQUIC_SUBJECT_DIR}/pingu.yaml"
        return 1
    fi

    local work_dir="/tmp/fuzzing-output"
    pushd "${HOME}/target/pingu" >/dev/null
    sudo -E timeout "${timeout}s" "${pingu_bin}" "${pingu_yaml}" --log4rs-config "/home/user/pingu/log4rs.yml" -vvv --purge fuzz || true
    sudo -E "${pingu_bin}" "${pingu_yaml}" --log4rs-config "/home/user/pingu/log4rs.yml" -vvv gcov --purge
    sudo chmod -R 755 "${work_dir}"
    sudo chown -R "$(id -u):$(id -g)" "${work_dir}"
    popd >/dev/null
}

function run_ft {
    local replay_step="${1:-1}"
    local gcov_step="${2:-1}"
    local timeout="${3:-300}"
    local work_dir=/tmp/fuzzing-output

    local target_root
    target_root=$(_target_root)
    local source_yaml="${HOME}/profuzzbench/subjects/QUIC/msquic/ft-source.yaml"
    local sink_yaml="${HOME}/profuzzbench/subjects/QUIC/msquic/ft-sink.yaml"
    if [ ! -f "${source_yaml}" ] || [ ! -f "${sink_yaml}" ]; then
        echo "[!] run_ft failed: missing ft yaml(s): ${source_yaml} or ${sink_yaml}"
        return 1
    fi
    pushd "${target_root}/ft" >/dev/null
    export LD_LIBRARY_PATH="${HOME}/fuzztruction-net/target/release:${LD_LIBRARY_PATH:-}"
    echo "${HOME}/fuzztruction-net/target/release" | sudo tee /etc/ld.so.conf.d/fuzztruction-net.conf >/dev/null
    sudo ldconfig

    local temp_file
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" \
        -e "s|UID|$(id -u)|g" \
        -e "s|GID|$(id -g)|g" \
        "${HOME}/profuzzbench/ft-common.yaml" >"${temp_file}"
    cat "${temp_file}" > ft.yaml
    printf "\n" >> ft.yaml
    rm -f "${temp_file}"

    cat "${source_yaml}" >> ft.yaml
    cat "${sink_yaml}" >> ft.yaml

    sudo -E "${HOME}/fuzztruction-net/target/release/fuzztruction" --log-level trace --purge ft.yaml fuzz -t "${timeout}s" || return 1
    sudo -E "${HOME}/fuzztruction-net/target/release/fuzztruction" --log-level trace ft.yaml gcov -t 3s --replay-step "${replay_step}" --gcov-step "${gcov_step}" || return 1
    sudo chmod -R 755 "${work_dir}"
    sudo chown -R "$(id -u):$(id -g)" "${work_dir}"

    popd >/dev/null
}

function build_asan {
    _ensure_msquic_repo || return 1
    local target_root
    target_root=$(_target_root)

    mkdir -p "${target_root}/asan"
    rm -rf "${target_root}/asan"/*
    cp -r repo/msquic "${target_root}/asan/msquic"

    _configure_and_build_msquic \
        "gcc" \
        "g++" \
        "-O0 -g -fsanitize=address" \
        "-O0 -g -fsanitize=address" \
        "-fsanitize=address" \
        "${target_root}/asan/msquic" \
        "${target_root}/asan/msquic/build" || return 1
}

function build_gcov {
    _ensure_msquic_repo || return 1
    local target_root
    target_root=$(_target_root)

    mkdir -p "${target_root}/gcov"
    rm -rf "${target_root}/gcov"/*
    cp -r repo/msquic "${target_root}/gcov/msquic"

    _configure_and_build_msquic \
        "gcc" \
        "g++" \
        "-O0 -g -fprofile-arcs -ftest-coverage" \
        "-O0 -g -fprofile-arcs -ftest-coverage" \
        "-fprofile-arcs -ftest-coverage" \
        "${target_root}/gcov/msquic" \
        "${target_root}/gcov/msquic/build" || return 1
}

function install_dependencies {
    export http_proxy="${HTTP_PROXY:-${http_proxy:-}}"
    export https_proxy="${HTTPS_PROXY:-${https_proxy:-${http_proxy:-}}}"
    sudo -E mkdir -p /var/lib/apt/lists/partial
    sudo -E apt-get update
    sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libev-dev libnuma-dev
}
