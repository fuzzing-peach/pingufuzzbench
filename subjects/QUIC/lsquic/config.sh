#!/usr/bin/env bash

if [ -z "${MAKE_OPT+x}" ] || [ -z "${MAKE_OPT}" ]; then
    MAKE_OPT="-j$(nproc)"
fi

LSQUIC_BASELINE="v4.4.2"
BORINGSSL_BASELINE="75a1350"
NGTCP2_BASELINE="28d3126"
WOLFSSL_BASELINE="b3f08f3"
NGHTTP3_BASELINE="21526d7"

if [ -d "${HOME}/profuzzbench" ]; then
    PFB_ROOT="${HOME}/profuzzbench"
else
    PFB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

function resolve_target_root {
    local root="${PFB_ROOT}/target"
    if [ ! -d "${root}" ]; then
        root="${HOME}/target"
    fi
    echo "${root}"
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

function clone_boringssl_retry {
    local dst="$1"
    local retries="${2:-3}"

    if git_clone_retry https://boringssl.googlesource.com/boringssl "${dst}" "${retries}" 0; then
        return 0
    fi

    git_clone_retry https://github.com/google/boringssl.git "${dst}" "${retries}" 0
}

function maybe_commit_patch {
    local msg="$1"
    if ! git diff --quiet; then
        git add .
        git commit -m "${msg}"
    fi
}

function cert_dir {
    echo "${PFB_ROOT}/cert"
}

function afl_replay_bin {
    if [ -x "${HOME}/aflnet/aflnet-replay" ]; then
        echo "${HOME}/aflnet/aflnet-replay"
    else
        echo "${HOME}/aflnet/afl-replay"
    fi
}

function _wait_udp_port {
    local port="$1"
    local rounds="${2:-30}"

    for _ in $(seq 1 "${rounds}"); do
        if ss -lunH 2>/dev/null | awk '{print $5}' | grep -Eq "(^|:)${port}$"; then
            return 0
        fi
        sleep 0.1
    done

    return 1
}

function _prepare_variant_dir {
    local variant="$1"
    local target_root
    target_root=$(resolve_target_root)

    mkdir -p "${target_root}/${variant}"
    rm -rf "${target_root:?}/${variant}"/*

    cp -r repo/lsquic "${target_root}/${variant}/lsquic"
    cp -r repo/boringssl "${target_root}/${variant}/boringssl"
}

function _configure_build_boringssl {
    local src_dir="$1"
    local cc_bin="$2"
    local cxx_bin="$3"
    local cflags="$4"
    local cxxflags="$5"
    local ldflags="$6"

    pushd "${src_dir}" >/dev/null
    rm -rf build
    CC="${cc_bin}" CXX="${cxx_bin}" CFLAGS="${cflags}" CXXFLAGS="${cxxflags}" LDFLAGS="${ldflags}" \
        cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build ${MAKE_OPT}
    popd >/dev/null
}

function _configure_build_lsquic {
    local src_dir="$1"
    local boringssl_dir="$2"
    local cc_bin="$3"
    local cxx_bin="$4"
    local cflags="$5"
    local cxxflags="$6"
    local ldflags="$7"

    pushd "${src_dir}" >/dev/null
    rm -rf build
    CC="${cc_bin}" CXX="${cxx_bin}" CFLAGS="${cflags}" CXXFLAGS="${cxxflags}" LDFLAGS="${ldflags}" \
        cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DLSQUIC_BIN=ON \
        -DLSQUIC_TESTS=OFF \
        -DLSQUIC_SHARED_LIB=OFF \
        -DLSQUIC_LIBSSL=BORINGSSL \
        -DBORINGSSL_INCLUDE="${boringssl_dir}/include" \
        -DBORINGSSL_LIB_ssl="${boringssl_dir}/build/ssl/libssl.a" \
        -DBORINGSSL_LIB_crypto="${boringssl_dir}/build/crypto/libcrypto.a"
    cmake --build build ${MAKE_OPT}

    if [ ! -x "${src_dir}/build/bin/http_server" ]; then
        echo "[!] build failed: ${src_dir}/build/bin/http_server was not generated"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
}

function _select_gcov_exec {
    local sample_gcno
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)

    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        if command -v llvm-cov-17 >/dev/null 2>&1; then
            echo "llvm-cov-17 gcov"
            return 0
        fi
        if command -v llvm-cov >/dev/null 2>&1; then
            echo "llvm-cov gcov"
            return 0
        fi
    fi

    echo "gcov"
}

function _fix_lsq_gcov_symlinks {
    if [ -f "src/liblsquic/ls-sfparser.c" ] && [ ! -e "ls-sfparser.c" ]; then
        ln -s "src/liblsquic/ls-sfparser.c" "ls-sfparser.c"
    fi

    if [ -f "src/liblsquic/ls-sfparser.h" ] && [ ! -e "ls-sfparser.h" ]; then
        ln -s "src/liblsquic/ls-sfparser.h" "ls-sfparser.h"
    fi

    if [ -d "src/liblsquic" ] && [ ! -e "liblsquic" ]; then
        ln -s "src/liblsquic" "liblsquic"
    fi
}

function _replay_http_server_case {
    local testcase="$1"
    local certs
    certs=$(cert_dir)
    local fake_time_value="${FAKE_TIME:-2026-03-11 12:00:00}"

    LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${fake_time_value}" \
        ./build/bin/http_server \
        -s 127.0.0.1:4433 \
        -c "www.example.com,${certs}/fullchain.crt,${certs}/server.key" >/tmp/lsquic-replay.log 2>&1 &
    local server_pid=$!

    _wait_udp_port 4433 40 || true
    timeout -s INT -k 1s 5s "$(afl_replay_bin)" "${testcase}" NOP 4433 100 || true
    kill -INT "${server_pid}" >/dev/null 2>&1 || true
    wait "${server_pid}" >/dev/null 2>&1 || true
}

function checkout {
    local target_ref="${1:-$LSQUIC_BASELINE}"
    mkdir -p .git-cache repo

    if [ ! -d ".git-cache/lsquic/.git" ]; then
        git_clone_retry https://github.com/litespeedtech/lsquic.git .git-cache/lsquic || return 1
    else
        pushd .git-cache/lsquic >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi

    rm -rf repo/lsquic
    cp -r .git-cache/lsquic repo/lsquic
    pushd repo/lsquic >/dev/null
    git checkout "${LSQUIC_BASELINE}"
    git submodule update --init --recursive
    git apply "${PFB_ROOT}/subjects/QUIC/lsquic/lsquic-time.patch" || return 1
    maybe_commit_patch "apply lsquic deterministic time patch"
    patch_commit=$(git rev-parse HEAD)
    if [ "${target_ref}" != "${LSQUIC_BASELINE}" ]; then
        git checkout "${target_ref}"
        git cherry-pick "${patch_commit}" || return 1
    fi
    popd >/dev/null

    if [ ! -d ".git-cache/boringssl/.git" ]; then
        clone_boringssl_retry .git-cache/boringssl || return 1
    else
        pushd .git-cache/boringssl >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi

    rm -rf repo/boringssl
    cp -r .git-cache/boringssl repo/boringssl
    pushd repo/boringssl >/dev/null
    git checkout "${BORINGSSL_BASELINE}" || true
    git apply "${PFB_ROOT}/subjects/QUIC/lsquic/lsquic-random.patch" || return 1
    maybe_commit_patch "apply boringssl deterministic random patch"
    popd >/dev/null

    if [ ! -d ".git-cache/ngtcp2/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/ngtcp2 .git-cache/ngtcp2 || return 1
    else
        pushd .git-cache/ngtcp2 >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/ngtcp2
    cp -r .git-cache/ngtcp2 repo/ngtcp2
    pushd repo/ngtcp2 >/dev/null
    git checkout "${NGTCP2_BASELINE}"
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
    git checkout "${WOLFSSL_BASELINE}"
    popd >/dev/null

    if [ ! -d ".git-cache/nghttp3/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/nghttp3 .git-cache/nghttp3 || return 1
    else
        pushd .git-cache/nghttp3 >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/nghttp3
    cp -r .git-cache/nghttp3 repo/nghttp3
    pushd repo/nghttp3 >/dev/null
    git checkout "${NGHTTP3_BASELINE}"
    git submodule update --init --recursive
    popd >/dev/null
}

function install_dependencies {
    sudo mkdir -p /var/lib/apt/lists/partial
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libevent-dev \
        libev-dev \
        zlib1g-dev \
        cmake \
        golang-go \
        autoconf \
        automake \
        libtool \
        pkg-config \
        python3-pip
    python3 -m pip install --user --break-system-packages wllvm || true
    sudo rm -rf /var/lib/apt/lists/*
}

function replay {
    _replay_http_server_case "$1"
}

function build_aflnet {
    local target_root
    target_root=$(resolve_target_root)

    _prepare_variant_dir aflnet

    _configure_build_boringssl \
        "${target_root}/aflnet/boringssl" \
        "gcc" "g++" "-O2 -g" "-O2 -g" ""

    export AFL_USE_ASAN=1
    _configure_build_lsquic \
        "${target_root}/aflnet/lsquic" \
        "${target_root}/aflnet/boringssl" \
        "${HOME}/aflnet/afl-clang-fast" "${HOME}/aflnet/afl-clang-fast++" \
        "-g -O2 -fsanitize=address" "-g -O2 -fsanitize=address" "-fsanitize=address"
}

function run_aflnet {
    local replay_step=$1
    local gcov_step=$2
    local timeout=$3
    local outdir=/tmp/fuzzing-output
    local indir="${PFB_ROOT}/subjects/QUIC/lsquic/seed-replay"
    local certs
    certs=$(cert_dir)
    local target_root
    target_root=$(resolve_target_root)

    if [ ! -d "${indir}" ]; then
        echo "[!] AFLNet seed-replay dir not found: ${indir}"
        return 1
    fi

    pushd "${target_root}/aflnet/lsquic" >/dev/null

    mkdir -p "${outdir}"

    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -s INT -k 1s --preserve-status "${timeout}" \
        "${HOME}/aflnet/afl-fuzz" \
        -d -i "${indir}" -o "${outdir}" -N "udp://127.0.0.1/4433 " \
        -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
        -- \
        "${target_root}/aflnet/lsquic/build/bin/http_server" \
        -s 127.0.0.1:4433 \
        -c "www.example.com,${certs}/fullchain.crt,${certs}/server.key" || true

    cd "${target_root}/gcov/lsquic"
    _fix_lsq_gcov_symlinks
    gcov_exec=$(_select_gcov_exec)
    gcov_common_opts="--gcov-executable \"${gcov_exec}\" -r ."
    eval "gcovr ${gcov_common_opts} -s -d" >/dev/null 2>&1 || true
    list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    compute_coverage replay "$list_cmd" "${gcov_step}" "${outdir}/coverage.csv" "$cov_cmd" ""
    mkdir -p "${outdir}/cov_html"
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
}

function build_sgfuzz {
    local target_root
    target_root=$(resolve_target_root)

    _prepare_variant_dir sgfuzz

    _configure_build_boringssl \
        "${target_root}/sgfuzz/boringssl" \
        "gcc" "g++" "-O2 -g" "-O2 -g" ""

    pushd "${target_root}/sgfuzz/lsquic" >/dev/null

    export PATH="${HOME}/.local/bin:${PATH}"
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ"

    python3 "${HOME}/sgfuzz/sanitizer/State_machine_instrument.py" . || true

    rm -rf build
    cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DLSQUIC_BIN=ON \
        -DLSQUIC_TESTS=OFF \
        -DLSQUIC_LIBSSL=BORINGSSL \
        -DBORINGSSL_INCLUDE="${target_root}/sgfuzz/boringssl/include" \
        -DBORINGSSL_LIB_ssl="${target_root}/sgfuzz/boringssl/build/ssl/libssl.a" \
        -DBORINGSSL_LIB_crypto="${target_root}/sgfuzz/boringssl/build/crypto/libcrypto.a"
    cmake --build build ${MAKE_OPT}

    if [ ! -x "build/bin/http_server" ]; then
        echo "[!] build_sgfuzz failed: build/bin/http_server not found"
        popd >/dev/null
        return 1
    fi

    pushd build/bin >/dev/null
    extract-bc ./http_server

    cat > hf_udp_addr.c <<'EOC'
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
    in->sin_port = htons(4433);
    in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    *type = SOCK_DGRAM;
    *protocol = IPPROTO_UDP;
    return (socklen_t)sizeof(*in);
}
EOC

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE="${target_root}/sgfuzz/lsquic/enum_types.txt"

    opt -load-pass-plugin="${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so" \
        -passes="sgfuzz-source" -debug-pass-manager http_server.bc -o http_server_opt.bc
    llvm-dis-17 http_server_opt.bc -o http_server_opt.ll
    sed -i 's/optnone //g;s/optnone//g' http_server_opt.ll

    clang http_server_opt.ll hf_udp_addr.c -o http_server \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DSGFUZZ \
        -lsFuzzer \
        -lhfnetdriver \
        -lhfcommon \
        -L"${target_root}/sgfuzz/lsquic/build/lib" -llsquic \
        -L"${target_root}/sgfuzz/boringssl/build/ssl" -lssl \
        -L"${target_root}/sgfuzz/boringssl/build/crypto" -lcrypto \
        -levent -ldl -lm -lz -lpthread -lstdc++

    popd >/dev/null
    popd >/dev/null
}

function run_sgfuzz {
    local replay_step=$1
    local gcov_step=$2
    local timeout=$3
    local outdir=/tmp/fuzzing-output
    local queue="${outdir}/replayable-queue"
    local indir="${PFB_ROOT}/subjects/QUIC/lsquic/seed"
    local certs
    certs=$(cert_dir)
    local target_root
    target_root=$(resolve_target_root)

    pushd "${target_root}/sgfuzz/lsquic/build/bin" >/dev/null

    mkdir -p "${queue}"
    rm -rf "${queue}"/*
    mkdir -p "${outdir}/crashes"

    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export HFND_TESTCASE_BUDGET_MS="${HFND_TESTCASE_BUDGET_MS:-50}"
    export HFND_TCP_PORT=4433

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -shrink=1
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time="${timeout}"
        -artifact_prefix="${outdir}/crashes/"
        "${queue}"
        "${indir}"
    )

    ./http_server "${SGFuzz_ARGS[@]}" \
        -- \
        -s 127.0.0.1:4433 \
        -c "www.example.com,${certs}/fullchain.crt,${certs}/server.key" || true

    python3 "${PFB_ROOT}/scripts/sort_libfuzzer_findings.py" "${queue}" || true

    cd "${target_root}/gcov/lsquic"
    _fix_lsq_gcov_symlinks

    function replay_sgfuzz_one {
        _replay_http_server_case "$1"
    }

    gcov_exec=$(_select_gcov_exec)
    gcov_common_opts="--gcov-executable \"${gcov_exec}\" -r ."
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    list_cmd="find ${queue} -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    compute_coverage replay_sgfuzz_one "$list_cmd" "${gcov_step}" "${outdir}/coverage.csv" "$cov_cmd" ""

    mkdir -p "${outdir}/cov_html"
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
}

function build_ft_generator {
    local target_root
    target_root=$(resolve_target_root)

    mkdir -p "${target_root}/ft/generator"
    rm -rf "${target_root}/ft/generator"/*
    cp -r repo/ngtcp2 "${target_root}/ft/generator/ngtcp2"
    cp -r repo/wolfssl "${target_root}/ft/generator/wolfssl"
    cp -r repo/nghttp3 "${target_root}/ft/generator/nghttp3"

    pushd "${target_root}/ft/generator/wolfssl" >/dev/null
    autoreconf -i
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    ./configure --prefix="${PWD}/build" --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${target_root}/ft/generator/nghttp3" >/dev/null
    autoreconf -i
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    ./configure --prefix="${PWD}/build" --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${target_root}/ft/generator/ngtcp2" >/dev/null
    autoreconf -i
    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=branch,load,store,select,switch
    export CC="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast"
    export CXX="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++"
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    export PKG_CONFIG_PATH="${target_root}/ft/generator/wolfssl/build/lib/pkgconfig:${target_root}/ft/generator/nghttp3/build/lib/pkgconfig"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT}

    if [ ! -x "${PWD}/examples/wsslclient" ]; then
        echo "[!] build_ft_generator failed: examples/wsslclient not found"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
}

function build_ft_consumer {
    local target_root
    target_root=$(resolve_target_root)

    mkdir -p "${target_root}/ft/consumer"
    rm -rf "${target_root}/ft/consumer"/*
    cp -r repo/lsquic "${target_root}/ft/consumer/lsquic"
    cp -r repo/boringssl "${target_root}/ft/consumer/boringssl"

    _configure_build_boringssl \
        "${target_root}/ft/consumer/boringssl" \
        "gcc" "g++" "-O2 -g" "-O2 -g" ""

    local aflpp_consumer="${HOME}/fuzztruction-net/consumer/aflpp-consumer"
    export AFL_PATH="${aflpp_consumer}"

    _configure_build_lsquic \
        "${target_root}/ft/consumer/lsquic" \
        "${target_root}/ft/consumer/boringssl" \
        "${aflpp_consumer}/afl-clang-fast" "${aflpp_consumer}/afl-clang-fast++" \
        "-O3 -g -DFT_FUZZING -DFT_CONSUMER -fsanitize=address" \
        "-O3 -g -DFT_FUZZING -DFT_CONSUMER -fsanitize=address" \
        "-fsanitize=address"
}

function run_ft {
    local replay_step=$1
    local gcov_step=$2
    local timeout=$3
    local work_dir=/tmp/fuzzing-output
    local target_root
    target_root=$(resolve_target_root)

    pushd "${target_root}/ft" >/dev/null

    local temp_file
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" \
        -e "s|UID|$(id -u)|g" \
        -e "s|GID|$(id -g)|g" \
        "${PFB_ROOT}/ft-common.yaml" >"${temp_file}"
    cat "${temp_file}" >ft.yaml
    printf "\n" >>ft.yaml
    rm -f "${temp_file}"

    sed "s|/home/user|${HOME}|g" "${PFB_ROOT}/subjects/QUIC/lsquic/ft-source.yaml" >>ft.yaml
    printf "\n" >>ft.yaml
    sed "s|/home/user|${HOME}|g" "${PFB_ROOT}/subjects/QUIC/lsquic/ft-sink.yaml" >>ft.yaml

    sudo "${HOME}/fuzztruction-net/target/release/fuzztruction" --log-level info --purge ft.yaml fuzz -t "${timeout}s"
    sudo "${HOME}/fuzztruction-net/target/release/fuzztruction" --log-level info ft.yaml gcov -t 3s \
        --replay-step "${replay_step}" --gcov-step "${gcov_step}"

    sudo chmod -R 755 "${work_dir}" || true
    sudo chown -R "$(id -u):$(id -g)" "${work_dir}" || true

    popd >/dev/null
}

function build_quicfuzz {
    echo "Not implemented"
    return 1
}

function run_quicfuzz {
    echo "Not implemented"
    return 1
}

function build_stateafl {
    echo "Not implemented"
    return 1
}

function run_stateafl {
    echo "Not implemented"
    return 1
}

function build_asan {
    local target_root
    target_root=$(resolve_target_root)

    _prepare_variant_dir asan
    _configure_build_boringssl \
        "${target_root}/asan/boringssl" \
        "clang" "clang++" "-O1 -g -fsanitize=address" "-O1 -g -fsanitize=address" "-fsanitize=address"

    _configure_build_lsquic \
        "${target_root}/asan/lsquic" \
        "${target_root}/asan/boringssl" \
        "clang" "clang++" \
        "-O1 -g -fsanitize=address" "-O1 -g -fsanitize=address" "-fsanitize=address"
}

function build_gcov {
    local target_root
    target_root=$(resolve_target_root)

    _prepare_variant_dir gcov
    _configure_build_boringssl \
        "${target_root}/gcov/boringssl" \
        "gcc" "g++" "-O0 -g" "-O0 -g" ""

    _configure_build_lsquic \
        "${target_root}/gcov/lsquic" \
        "${target_root}/gcov/boringssl" \
        "gcc" "g++" \
        "-fprofile-arcs -ftest-coverage -O0 -g" \
        "-fprofile-arcs -ftest-coverage -O0 -g" \
        "-fprofile-arcs -ftest-coverage"
}

function cleanup_artifacts {
    local target_root
    target_root=$(resolve_target_root)

    rm -rf "${target_root}/aflnet/lsquic/build/CMakeFiles" \
        "${target_root}/gcov/lsquic/build/CMakeFiles" \
        "${target_root}/asan/lsquic/build/CMakeFiles" \
        "${target_root}/sgfuzz/lsquic/build/CMakeFiles" 2>/dev/null || true
}
