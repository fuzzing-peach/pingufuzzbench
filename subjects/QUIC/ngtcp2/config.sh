#!/usr/bin/env bash

if [ -z "${MAKE_OPT+x}" ] || [ -z "${MAKE_OPT}" ]; then
    MAKE_OPT="-j$(nproc)"
fi

PINGU_PASS_DIR="${HOME}/pingu/pingu-agent/pass/build"

function git_clone_retry {
    url="$1"
    dst="$2"
    recursive="${4:-1}"
    retries="${3:-3}"
    i=1
    while [ "$i" -le "$retries" ]; do
        rm -rf "${dst}"
        if [ "${recursive}" = "1" ]; then
            clone_opts="--filter=blob:none --recursive"
        else
            clone_opts="--filter=blob:none"
        fi
        if git clone ${clone_opts} "${url}" "${dst}"; then
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

function checkout {
    ngtcp2_baseline="28d3126"
    target_ref="${1:-$ngtcp2_baseline}"

    mkdir -p "${HOME}/repo/ngtcp2"

    if [ ! -d "${HOME}/.git-cache/ngtcp2/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/ngtcp2 ${HOME}/.git-cache/ngtcp2 || return 1
    else
        pushd ${HOME}/.git-cache/ngtcp2 >/dev/null
        git reset --hard HEAD
        git clean -fdx
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf ${HOME}/repo/ngtcp2/ngtcp2
    cp -r ${HOME}/.git-cache/ngtcp2 ${HOME}/repo/ngtcp2/ngtcp2
    pushd ${HOME}/repo/ngtcp2/ngtcp2 >/dev/null
    git checkout "${ngtcp2_baseline}"
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/quicfuzz-ngtcp2.patch || return 1
    git add .
    git commit -m "apply quicfuzz-ngtcp2 patch"
    patch_commit=$(git rev-parse HEAD)
    if [ "${target_ref}" != "${ngtcp2_baseline}" ]; then
        git checkout "${target_ref}"
        git cherry-pick "${patch_commit}" || return 1
    fi
    git submodule update --init --recursive
    popd >/dev/null

    if [ ! -d "${HOME}/.git-cache/wolfssl/.git" ]; then
        git_clone_retry https://github.com/wolfSSL/wolfssl ${HOME}/.git-cache/wolfssl || return 1
    else
        pushd ${HOME}/.git-cache/wolfssl >/dev/null
        git reset --hard HEAD
        git clean -fdx
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf ${HOME}/repo/ngtcp2/wolfssl
    cp -r ${HOME}/.git-cache/wolfssl ${HOME}/repo/ngtcp2/wolfssl
    pushd ${HOME}/repo/ngtcp2/wolfssl >/dev/null
    git checkout b3f08f3
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/wolfssl-random.patch || return 1
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/wolfssl-time.patch || return 1
    git add .
    git commit -m "apply wolfssl deterministic random/time patches"
    popd >/dev/null

    if [ ! -d "${HOME}/.git-cache/nghttp3/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/nghttp3 ${HOME}/.git-cache/nghttp3 || return 1
    else
        pushd ${HOME}/.git-cache/nghttp3 >/dev/null
        git reset --hard HEAD
        git clean -fdx
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf ${HOME}/repo/ngtcp2/nghttp3
    cp -r ${HOME}/.git-cache/nghttp3 ${HOME}/repo/ngtcp2/nghttp3
    pushd ${HOME}/repo/ngtcp2/nghttp3 >/dev/null
    git checkout 21526d7
    git submodule update --init --recursive
    popd >/dev/null

}

function replay {
    cert_dir=${HOME}/profuzzbench/cert
    fake_time_value="${FAKE_TIME:-2026-03-11 12:00:00}"
    LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${fake_time_value}" \
        ./examples/wsslserver 127.0.0.1 4433 \
        ${cert_dir}/server.key \
        ${cert_dir}/fullchain.crt --initial-pkt-num=0 &
    server_pid=$!
    sleep 1
    timeout -s INT -k 1s 5s ${HOME}/aflnet/aflnet-replay "$1" NOP 4433 100 || true
    kill -INT ${server_pid} >/dev/null 2>&1 || true
    wait ${server_pid} || true
}

function build_aflnet {
    mkdir -p ${HOME}/target/aflnet/ngtcp2
    rm -rf ${HOME}/target/aflnet/ngtcp2/*
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 ${HOME}/target/aflnet/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/wolfssl ${HOME}/target/aflnet/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/nghttp3 ${HOME}/target/aflnet/ngtcp2/

    pushd ${HOME}/target/aflnet/ngtcp2/wolfssl >/dev/null
    autoreconf -i
    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd ${HOME}/target/aflnet/ngtcp2/nghttp3 >/dev/null
    autoreconf -i
    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd ${HOME}/target/aflnet/ngtcp2/ngtcp2 >/dev/null
    autoreconf -i
    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    export PKG_CONFIG_PATH=${HOME}/target/aflnet/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/aflnet/ngtcp2/nghttp3/build/lib/pkgconfig
    ./configure --with-wolfssl --disable-shared --enable-static --enable-asan
    make ${MAKE_OPT} check
    if [ ! -x "${PWD}/examples/wsslserver" ]; then
        echo "[!] build_aflnet failed: ${PWD}/examples/wsslserver was not generated"
        return 1
    fi
    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/seed-replay
    cert_dir=${HOME}/profuzzbench/cert

    pushd ${HOME}/target/aflnet/ngtcp2/ngtcp2 >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -s INT -k 1s --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz \
        -d -i ${indir} -o ${outdir} -N "udp://127.0.0.1/4433 " \
        -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
        -- \
        ${HOME}/target/aflnet/ngtcp2/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        ${cert_dir}/server.key \
        ${cert_dir}/fullchain.crt --initial-pkt-num=0 || true

    cd ${HOME}/target/gcov/ngtcp2/ngtcp2
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    # Resolve relative source paths referenced by crypto/shared.gcda.
    ln -sfn ${HOME}/target/gcov/ngtcp2/ngtcp2/crypto/shared.c ${HOME}/target/gcov/ngtcp2/ngtcp2/shared.c
    mkdir -p ${HOME}/target/gcov/lib
    if [ ! -e ${HOME}/target/gcov/lib/ngtcp2_macro.h ]; then
        ln -s ${HOME}/target/gcov/ngtcp2/ngtcp2/lib/ngtcp2_macro.h ${HOME}/target/gcov/lib/ngtcp2_macro.h
    fi
    # Choose a gcov backend based on gcno format:
    # - GCC-style gcno (e.g., B33*) => use gcov
    # - LLVM gcno (e.g., 408*) => use llvm-cov gcov
    gcov_exec="gcov"
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)
    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        gcov_exec="llvm-cov-17 gcov"
    fi
    gcov_common_opts="--gcov-executable \"${gcov_exec}\" -r ."
    list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$cov_cmd" ""
    mkdir -p ${outdir}/cov_html
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
}

function build_stateafl {
    mkdir -p ${HOME}/target/stateafl/ngtcp2
    rm -rf ${HOME}/target/stateafl/ngtcp2/*
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 ${HOME}/target/stateafl/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/wolfssl ${HOME}/target/stateafl/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/nghttp3 ${HOME}/target/stateafl/ngtcp2/

    pushd ${HOME}/target/stateafl/ngtcp2/wolfssl >/dev/null
    autoreconf -i
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd ${HOME}/target/stateafl/ngtcp2/nghttp3 >/dev/null
    autoreconf -i
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd ${HOME}/target/stateafl/ngtcp2/ngtcp2 >/dev/null
    autoreconf -i
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    export PKG_CONFIG_PATH=${HOME}/target/stateafl/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/stateafl/ngtcp2/nghttp3/build/lib/pkgconfig
    ./configure --with-wolfssl --disable-shared --enable-static --enable-asan
    make ${MAKE_OPT}
    if [ ! -x "${PWD}/examples/wsslserver" ]; then
        echo "[!] build_stateafl failed: ${PWD}/examples/wsslserver was not generated"
        return 1
    fi
    popd >/dev/null
}

function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/seed-replay
    cert_dir=${HOME}/profuzzbench/cert

    pushd ${HOME}/target/stateafl/ngtcp2/ngtcp2 >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -s INT -k 1s --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz \
        -d -i ${indir} -o ${outdir} -N "udp://127.0.0.1/4433 " \
        -P NOP -D 10000 -q 3 -s 3 -K -R -W 100 -m none \
        -- \
        ${HOME}/target/stateafl/ngtcp2/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        ${cert_dir}/server.key \
        ${cert_dir}/fullchain.crt --initial-pkt-num=0 || true

    cd ${HOME}/target/gcov/ngtcp2/ngtcp2
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    ln -sfn ${HOME}/target/gcov/ngtcp2/ngtcp2/crypto/shared.c ${HOME}/target/gcov/ngtcp2/ngtcp2/shared.c
    mkdir -p ${HOME}/target/gcov/lib
    if [ ! -e ${HOME}/target/gcov/lib/ngtcp2_macro.h ]; then
        ln -s ${HOME}/target/gcov/ngtcp2/ngtcp2/lib/ngtcp2_macro.h ${HOME}/target/gcov/lib/ngtcp2_macro.h
    fi
    gcov_exec="gcov"
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)
    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        gcov_exec="llvm-cov-17 gcov"
    fi
    gcov_common_opts="--gcov-executable \"${gcov_exec}\" -r ."
    eval "gcovr ${gcov_common_opts} -s -d" >/dev/null 2>&1 || true
    list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$cov_cmd" ""
    mkdir -p ${outdir}/cov_html
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
}

function build_sgfuzz {
    target_root=${HOME}/profuzzbench/target
    if [ ! -d "${target_root}" ]; then
        target_root=${HOME}/target
    fi

    mkdir -p ${HOME}/target/sgfuzz/ngtcp2
    rm -rf ${HOME}/target/sgfuzz/ngtcp2/*
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 ${HOME}/target/sgfuzz/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/wolfssl ${HOME}/target/sgfuzz/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/nghttp3 ${HOME}/target/sgfuzz/ngtcp2/

    pushd ${HOME}/target/sgfuzz/ngtcp2/wolfssl >/dev/null
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-static --enable-shared=no --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd ${HOME}/target/sgfuzz/ngtcp2/nghttp3 >/dev/null
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd ${HOME}/target/sgfuzz/ngtcp2/ngtcp2 >/dev/null
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -v -Wno-int-conversion"
    export CXXFLAGS="-std=gnu++20 -O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -v -Wno-int-conversion"
    python3 ${HOME}/sgfuzz/sanitizer/State_machine_instrument.py .
    autoreconf -i
    export PKG_CONFIG_PATH=${target_root}/sgfuzz/ngtcp2/wolfssl/build/lib/pkgconfig:${target_root}/sgfuzz/ngtcp2/nghttp3/build/lib/pkgconfig
    export LIBS="-lm"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT}
    if [ ! -x "${PWD}/examples/wsslserver" ]; then
        make -C examples ${MAKE_OPT} wsslserver || true
    fi
    if [ ! -x "${PWD}/examples/wsslserver" ]; then
        echo "[!] build_sgfuzz failed: ${PWD}/examples/wsslserver was not generated"
        return 1
    fi

    pushd examples >/dev/null
    extract-bc ./wsslserver

    cat > hf_udp_addr.c <<'EOF'
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
EOF

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE=${target_root}/sgfuzz/ngtcp2/ngtcp2/enum_types.txt
    opt -load-pass-plugin=${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so \
        -passes="sgfuzz-source" -debug-pass-manager wsslserver.bc -o wsslserver_opt.bc
    llvm-dis-17 wsslserver_opt.bc -o wsslserver_opt.ll
    sed -i 's/optnone //g;s/optnone//g' wsslserver_opt.ll

    clang wsslserver_opt.ll hf_udp_addr.c -o wsslserver \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DSGFUZZ \
        -lsFuzzer \
        -lhfnetdriver \
        -lhfcommon \
        -L${target_root}/sgfuzz/ngtcp2/ngtcp2/lib/.libs \
        -lngtcp2 \
        -L${target_root}/sgfuzz/ngtcp2/ngtcp2/crypto/wolfssl/.libs \
        -lngtcp2_crypto_wolfssl \
        -L${target_root}/sgfuzz/ngtcp2/nghttp3/build/lib \
        -lnghttp3 \
        -L${target_root}/sgfuzz/ngtcp2/wolfssl/build/lib \
        -lwolfssl \
        -lev \
        -ldl \
        -lm \
        -lz \
        -lpthread \
        -lstdc++

    popd >/dev/null
    popd >/dev/null
}

function run_sgfuzz {
    target_root=${HOME}/target

    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    queue=${outdir}/replayable-queue
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/seed
    cert_dir=${HOME}/profuzzbench/cert

    pushd ${target_root}/sgfuzz/ngtcp2/ngtcp2/examples >/dev/null

    mkdir -p ${queue}
    rm -rf ${queue}/*
    mkdir -p ${outdir}/crashes
    rm -rf ${outdir}/crashes/*

    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export AFL_NO_UI=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"
    export HFND_TESTCASE_BUDGET_MS="${HFND_TESTCASE_BUDGET_MS:-50}"
    export HFND_TCP_PORT=4433
    export HFND_FORK_MODE=1
    export LD_LIBRARY_PATH=${target_root}/sgfuzz/ngtcp2/nghttp3/build/lib:${target_root}/sgfuzz/ngtcp2/wolfssl/build/lib:${target_root}/sgfuzz/ngtcp2/ngtcp2/lib/.libs:${target_root}/sgfuzz/ngtcp2/ngtcp2/crypto/wolfssl/.libs:${LD_LIBRARY_PATH:-}

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -shrink=1
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time=${timeout}
        -fork=1
        -ignore_crashes=1
        -artifact_prefix="${outdir}/crashes/"
        "${queue}"
        "${indir}"
    )

    ./wsslserver "${SGFuzz_ARGS[@]}" \
        -- \
        127.0.0.1 4433 \
        ${cert_dir}/server.key \
        ${cert_dir}/fullchain.crt --initial-pkt-num=0 || true

    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${queue}

    cd ${target_root}/gcov/ngtcp2/ngtcp2
    # Reset runtime counters before replay-based coverage collection.
    find . -name "*.gcda" -type f -delete || true
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    ln -sfn ${target_root}/gcov/ngtcp2/ngtcp2/crypto/shared.c ${target_root}/gcov/ngtcp2/ngtcp2/shared.c
    mkdir -p ${target_root}/gcov/lib
    if [ ! -e ${target_root}/gcov/lib/ngtcp2_macro.h ]; then
        ln -s ${target_root}/gcov/ngtcp2/ngtcp2/lib/ngtcp2_macro.h ${target_root}/gcov/lib/ngtcp2_macro.h
    fi

    function replay_sgfuzz_one {
        LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}" \
            timeout -s INT -k 1s 5s ./examples/wsslserver 127.0.0.1 4433 \
            ${cert_dir}/server.key \
            ${cert_dir}/fullchain.crt --initial-pkt-num=0 &
        server_pid=$!

        # Wait briefly for UDP listener to come up before replaying input.
        for _ in $(seq 1 20); do
            if ss -lunH 2>/dev/null | awk '{print $5}' | grep -Eq '(^|:)4433$'; then
                break
            fi
            sleep 0.1
        done

        timeout -s INT -k 1s 5s ${HOME}/aflnet/afl-replay "$1" NOP 4433 100 || true
        kill -INT "${server_pid}" 2>/dev/null || true
        wait "${server_pid}" 2>/dev/null || true
    }

    gcov_exec="gcov"
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)
    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        gcov_exec="llvm-cov-17 gcov"
    fi
    gcov_common_opts="--gcov-executable \"${gcov_exec}\" -r ."
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    list_cmd="find ${queue} -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    compute_coverage replay_sgfuzz_one "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$cov_cmd" ""

    mkdir -p ${outdir}/cov_html
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
}

function build_ft_generator {
    mkdir -p "${HOME}/target/ft/generator/ngtcp2"
    rm -rf "${HOME}/target/ft/generator/ngtcp2"/*
    cp -r ${HOME}/repo/ngtcp2/wolfssl "${HOME}/target/ft/generator/ngtcp2/wolfssl"
    cp -r ${HOME}/repo/ngtcp2/nghttp3 "${HOME}/target/ft/generator/ngtcp2/nghttp3"
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 "${HOME}/target/ft/generator/ngtcp2/ngtcp2"

    pushd "${HOME}/target/ft/generator/ngtcp2/wolfssl" >/dev/null
    autoreconf -i
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    ./configure --prefix="${PWD}/build" --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/ft/generator/ngtcp2/nghttp3" >/dev/null
    autoreconf -i
    ./configure --prefix="${PWD}/build" --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/ft/generator/ngtcp2/ngtcp2" >/dev/null
    autoreconf -i
    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=branch,load,store,select,switch
    export CC="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast"
    export CXX="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++"
    export CFLAGS="-O3 -g -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -DFT_GENERATOR"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"
    export LD_LIBRARY_PATH="${HOME}/fuzztruction-net/target/release:${LD_LIBRARY_PATH}"
    export PKG_CONFIG_PATH="${HOME}/target/ft/generator/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/ft/generator/ngtcp2/nghttp3/build/lib/pkgconfig"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT}
    if [ ! -x "${PWD}/examples/wsslclient" ]; then
        echo "[!] build_ft_generator failed: ${PWD}/examples/wsslclient not found"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
}

function build_ft_consumer {
    local afl_path="${HOME}/fuzztruction-net/consumer/aflpp-consumer"
    local ft_patch="${HOME}/profuzzbench/.trees/ngtcp2/subjects/QUIC/ngtcp2/msquic-ngtcp2-ft-exit.patch"

    if [ ! -x "${afl_path}/afl-clang-fast" ] || [ ! -x "${afl_path}/afl-clang-fast++" ]; then
        echo "[!] build_ft_consumer failed: missing ${afl_path}/afl-clang-fast(++)"
        return 1
    fi

    mkdir -p "${HOME}/target/ft/consumer/ngtcp2"
    rm -rf "${HOME}/target/ft/consumer/ngtcp2"/*
    cp -r ${HOME}/repo/ngtcp2/wolfssl "${HOME}/target/ft/consumer/ngtcp2/wolfssl"
    cp -r ${HOME}/repo/ngtcp2/nghttp3 "${HOME}/target/ft/consumer/ngtcp2/nghttp3"
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 "${HOME}/target/ft/consumer/ngtcp2/ngtcp2"

    pushd "${HOME}/target/ft/consumer/ngtcp2/wolfssl" >/dev/null
    autoreconf -i
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    ./configure --prefix="${PWD}/build" --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/ft/consumer/ngtcp2/nghttp3" >/dev/null
    autoreconf -i
    ./configure --prefix="${PWD}/build" --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/ft/consumer/ngtcp2/ngtcp2" >/dev/null
    if [ -f "${ft_patch}" ] && git apply --check "${ft_patch}" >/dev/null 2>&1; then
        git apply "${ft_patch}" || return 1
    fi
    autoreconf -i
    export CC="${afl_path}/afl-clang-fast"
    export CXX="${afl_path}/afl-clang-fast++"
    export CFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"
    export PKG_CONFIG_PATH="${HOME}/target/ft/consumer/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/ft/consumer/ngtcp2/nghttp3/build/lib/pkgconfig"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT}
    if [ ! -x "${PWD}/examples/wsslserver" ]; then
        echo "[!] build_ft_consumer failed: ${PWD}/examples/wsslserver not found"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null

    build_gcov || return 1
}

function run_ft {
    local replay_step="${1:-1}"
    local gcov_step="${2:-1}"
    local timeout="${3:-300}"
    local work_dir=/tmp/fuzzing-output
    local target_root="${HOME}/target"
    local ft_lib_path="${HOME}/fuzztruction-net/target/release:${LD_LIBRARY_PATH:-}"

    pkill -9 -x wsslserver >/dev/null 2>&1 || true
    pkill -9 -x wsslclient >/dev/null 2>&1 || true
    pkill -9 -x fuzztruction >/dev/null 2>&1 || true
    pushd "${target_root}/ft" >/dev/null

    local temp_file
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" \
        -e "s|UID|$(id -u)|g" \
        -e "s|GID|$(id -g)|g" \
        "${HOME}/profuzzbench/ft-common.yaml" >"${temp_file}"
    cat "${temp_file}" > ft.yaml
    printf "\n" >> ft.yaml
    rm -f "${temp_file}"

    cat "${HOME}/profuzzbench/.trees/ngtcp2/subjects/QUIC/ngtcp2/ft-source.yaml" >> ft.yaml
    cat "${HOME}/profuzzbench/.trees/ngtcp2/subjects/QUIC/ngtcp2/ft-sink.yaml" >> ft.yaml

    echo "${HOME}/fuzztruction-net/target/release" | sudo tee /etc/ld.so.conf.d/fuzztruction-net.conf >/dev/null
    sudo ldconfig

    sudo LD_LIBRARY_PATH="${ft_lib_path}" "${HOME}/fuzztruction-net/target/release/fuzztruction" --log-level info --purge ft.yaml fuzz -t "${timeout}s" || return 1
    cd "${target_root}/gcov/ngtcp2/ngtcp2"
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    ln -sfn "${target_root}/gcov/ngtcp2/ngtcp2/crypto/shared.c" "${target_root}/gcov/ngtcp2/ngtcp2/shared.c"
    mkdir -p "${target_root}/gcov/lib"
    if [ ! -e "${target_root}/gcov/lib/ngtcp2_macro.h" ]; then
        ln -s "${target_root}/gcov/ngtcp2/ngtcp2/lib/ngtcp2_macro.h" "${target_root}/gcov/lib/ngtcp2_macro.h"
    fi
    cd "${target_root}/ft"
    sudo LD_LIBRARY_PATH="${ft_lib_path}" "${HOME}/fuzztruction-net/target/release/fuzztruction" --log-level info ft.yaml gcov -t 3s --replay-step "${replay_step}" --gcov-step "${gcov_step}" || return 1
    sudo chmod -R 755 "${work_dir}"
    sudo chown -R "$(id -u):$(id -g)" "${work_dir}"

    popd >/dev/null
}

function build_pingu_generator {
    mkdir -p "${HOME}/target/pingu/generator/ngtcp2"
    rm -rf "${HOME}/target/pingu/generator/ngtcp2"/*
    cp -r ${HOME}/repo/ngtcp2/wolfssl "${HOME}/target/pingu/generator/ngtcp2/wolfssl"
    cp -r ${HOME}/repo/ngtcp2/nghttp3 "${HOME}/target/pingu/generator/ngtcp2/nghttp3"
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 "${HOME}/target/pingu/generator/ngtcp2/ngtcp2"

    pushd "${HOME}/target/pingu/generator/ngtcp2/wolfssl" >/dev/null
    autoreconf -i
    CC=gcc CXX=g++ ./configure --prefix="${PWD}/build" --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/pingu/generator/ngtcp2/nghttp3" >/dev/null
    if [ ! -f "lib/sfparse/sfparse.c" ]; then
        rm -rf lib/sfparse
        git clone --depth 1 https://github.com/ngtcp2/sfparse lib/sfparse
    fi
    autoreconf -i
    ./configure --prefix="${PWD}/build" --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/pingu/generator/ngtcp2/ngtcp2" >/dev/null
    if [ ! -f "third-party/urlparse/urlparse.h" ]; then
        rm -rf third-party/urlparse
        git clone --depth 1 https://github.com/ngtcp2/urlparse third-party/urlparse
    fi
    autoreconf -i
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export PKG_CONFIG_PATH="${HOME}/target/pingu/generator/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/pingu/generator/ngtcp2/nghttp3/build/lib/pkgconfig"
    ./configure --with-wolfssl --disable-shared --enable-static
    rm -f compile_commands.json
    bear --output compile_commands.json -- make ${MAKE_OPT}

    cd examples
    extract-bc wsslclient
    [ -f "${PWD}/wsslclient.bc" ] || { echo "[!] build_pingu_generator failed: examples/wsslclient.bc not found"; popd >/dev/null; return 1; }

    opt -load-pass-plugin=${PINGU_PASS_DIR}/pingu-source-pass.so \
        -passes="pingu-source" -debug-pass-manager \
        -src-root-dir="/home/user/target/pingu/generator/ngtcp2/ngtcp2" \
        -ins=load,store,call,memcpy,trampoline,ret,icmp,memcmp -role=source \
        wsslclient.bc -o wsslclient_opt.bc

    llvm-dis wsslclient_opt.bc -o wsslclient_opt.ll
    sed -i 's/optnone //g' wsslclient_opt.ll

    clang -O0 -L/home/user/pingu/target/release -Wl,-rpath,${HOME}/pingu/target/release \
        -Wl,--no-export-dynamic \
        -L"${HOME}/target/pingu/generator/ngtcp2/ngtcp2/lib/.libs" \
        -L"${HOME}/target/pingu/generator/ngtcp2/ngtcp2/crypto/wolfssl/.libs" \
        -L"${HOME}/target/pingu/generator/ngtcp2/nghttp3/build/lib" \
        -L"${HOME}/target/pingu/generator/ngtcp2/wolfssl/build/lib" \
        -Wl,-rpath,"${HOME}/target/pingu/generator/ngtcp2/ngtcp2/lib/.libs" \
        -Wl,-rpath,"${HOME}/target/pingu/generator/ngtcp2/ngtcp2/crypto/wolfssl/.libs" \
        -Wl,-rpath,"${HOME}/target/pingu/generator/ngtcp2/nghttp3/build/lib" \
        -Wl,-rpath,"${HOME}/target/pingu/generator/ngtcp2/wolfssl/build/lib" \
        -lpingu_agent -lngtcp2 -lngtcp2_crypto_wolfssl -lnghttp3 -lwolfssl \
        -lstdc++ -ldl -lz -lev -lpthread -lm -fsanitize=address \
        wsslclient_opt.ll -o wsslclient

    [ -x "${PWD}/wsslclient" ] || { echo "[!] build_pingu_generator failed: examples/wsslclient not found"; popd >/dev/null; return 1; }
    popd >/dev/null
}

function build_pingu_consumer {
    local ft_patch="${HOME}/profuzzbench/.trees/ngtcp2/subjects/QUIC/ngtcp2/msquic-ngtcp2-ft-exit.patch"

    mkdir -p "${HOME}/target/pingu/consumer/ngtcp2"
    rm -rf "${HOME}/target/pingu/consumer/ngtcp2"/*
    cp -r ${HOME}/repo/ngtcp2/wolfssl "${HOME}/target/pingu/consumer/ngtcp2/wolfssl"
    cp -r ${HOME}/repo/ngtcp2/nghttp3 "${HOME}/target/pingu/consumer/ngtcp2/nghttp3"
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 "${HOME}/target/pingu/consumer/ngtcp2/ngtcp2"

    pushd "${HOME}/target/pingu/consumer/ngtcp2/wolfssl" >/dev/null
    autoreconf -i
    CC=gcc CXX=g++ ./configure --prefix="${PWD}/build" --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/pingu/consumer/ngtcp2/nghttp3" >/dev/null
    if [ ! -f "lib/sfparse/sfparse.c" ]; then
        rm -rf lib/sfparse
        git clone --depth 1 https://github.com/ngtcp2/sfparse lib/sfparse
    fi
    autoreconf -i
    ./configure --prefix="${PWD}/build" --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd "${HOME}/target/pingu/consumer/ngtcp2/ngtcp2" >/dev/null
    if [ ! -f "third-party/urlparse/urlparse.h" ]; then
        rm -rf third-party/urlparse
        git clone --depth 1 https://github.com/ngtcp2/urlparse third-party/urlparse
    fi
    if git apply --check "${ft_patch}" >/dev/null 2>&1; then
        git apply "${ft_patch}"
    fi
    autoreconf -i
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -DFT_CONSUMER"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -DFT_CONSUMER"
    export PKG_CONFIG_PATH="${HOME}/target/pingu/consumer/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/pingu/consumer/ngtcp2/nghttp3/build/lib/pkgconfig"
    ./configure --with-wolfssl --disable-shared --enable-static
    rm -f compile_commands.json
    bear --output compile_commands.json -- make ${MAKE_OPT}

    cd examples
    extract-bc wsslserver
    [ -f "${PWD}/wsslserver.bc" ] || { echo "[!] build_pingu_consumer failed: examples/wsslserver.bc not found"; popd >/dev/null; return 1; }

    opt -load-pass-plugin=${PINGU_PASS_DIR}/pingu-source-pass.so \
        -load-pass-plugin=${PINGU_PASS_DIR}/afl-llvm-pass.so \
        -passes="pingu-source,afl-coverage" -debug-pass-manager \
        -src-root-dir="/home/user/target/pingu/consumer/ngtcp2/ngtcp2" \
        -ins=load,store,call,memcpy,icmp,memcmp,ret -role=sink \
        wsslserver.bc -o wsslserver_opt.bc

    llvm-dis wsslserver_opt.bc -o wsslserver_opt.ll
    sed -i 's/optnone //g' wsslserver_opt.ll

    clang -O0 -L/home/user/pingu/target/release -Wl,-rpath,${HOME}/pingu/target/release \
        -Wl,--no-export-dynamic \
        -L"${HOME}/target/pingu/consumer/ngtcp2/ngtcp2/lib/.libs" \
        -L"${HOME}/target/pingu/consumer/ngtcp2/ngtcp2/crypto/wolfssl/.libs" \
        -L"${HOME}/target/pingu/consumer/ngtcp2/nghttp3/build/lib" \
        -L"${HOME}/target/pingu/consumer/ngtcp2/wolfssl/build/lib" \
        -Wl,-rpath,"${HOME}/target/pingu/consumer/ngtcp2/ngtcp2/lib/.libs" \
        -Wl,-rpath,"${HOME}/target/pingu/consumer/ngtcp2/ngtcp2/crypto/wolfssl/.libs" \
        -Wl,-rpath,"${HOME}/target/pingu/consumer/ngtcp2/nghttp3/build/lib" \
        -Wl,-rpath,"${HOME}/target/pingu/consumer/ngtcp2/wolfssl/build/lib" \
        -lpingu_agent -lngtcp2 -lngtcp2_crypto_wolfssl -lnghttp3 -lwolfssl \
        -lstdc++ -ldl -lz -lev -lpthread -lm -fsanitize=address \
        wsslserver_opt.ll -o wsslserver

    [ -x "${PWD}/wsslserver" ] || { echo "[!] build_pingu_consumer failed: examples/wsslserver not found"; popd >/dev/null; return 1; }
    popd >/dev/null

}

function run_pingu {
    local replay_step="${1:-1}"
    local gcov_step="${2:-1}"
    local timeout="${3:-300}"
    local work_dir=/tmp/fuzzing-output
    local target_root="${HOME}/target"
    local pingu_bin="${HOME}/pingu/target/release/pingu"
    local pingu_template="${HOME}/profuzzbench/subjects/QUIC/ngtcp2/pingu.yaml"

    [ -x "${pingu_bin}" ] || { echo "[!] missing ${pingu_bin}"; return 1; }
    [ -f "${pingu_template}" ] || { echo "[!] missing ${pingu_template}"; return 1; }
    mkdir -p "${work_dir}"

    pushd "${target_root}/pingu" >/dev/null
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" \
        -e "s|UID|$(id -u)|g" \
        -e "s|GID|$(id -g)|g" \
        "${pingu_template}" > pingu.yaml

    sudo timeout "${timeout}s" "${pingu_bin}" pingu.yaml -v --purge fuzz || true
    sudo "${pingu_bin}" pingu.yaml -v gcov --pcap --purge
    sudo chmod -R 755 "${work_dir}"
    sudo chown -R "$(id -u):$(id -g)" "${work_dir}"
    popd >/dev/null
}

function build_quicfuzz {
    mkdir -p ${HOME}/target/quicfuzz/ngtcp2
    rm -rf ${HOME}/target/quicfuzz/ngtcp2/*
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 ${HOME}/target/quicfuzz/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/wolfssl ${HOME}/target/quicfuzz/ngtcp2/
    cp -r ${HOME}/repo/ngtcp2/nghttp3 ${HOME}/target/quicfuzz/ngtcp2/

    pushd ${HOME}/target/quicfuzz/ngtcp2/wolfssl >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT} && make install
    popd >/dev/null

    pushd ${HOME}/target/quicfuzz/ngtcp2/nghttp3 >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT} check && make install
    popd >/dev/null

    pushd ${HOME}/target/quicfuzz/ngtcp2/ngtcp2 >/dev/null
    autoreconf -i
    export CC=${HOME}/quic-fuzz/aflnet/afl-clang-fast
    export CXX=${HOME}/quic-fuzz/aflnet/afl-clang-fast++
    export PKG_CONFIG_PATH=${HOME}/target/quicfuzz/ngtcp2/wolfssl/build/lib/pkgconfig:${HOME}/target/quicfuzz/ngtcp2/nghttp3/build/lib/pkgconfig
    ./configure --with-wolfssl --disable-shared --enable-static
    export AFL_USE_ASAN=1
    export CFLAGS="-fsanitize=address -g"
    export CXXFLAGS="-fsanitize=address -g"
    export LDFLAGS="-fsanitize=address -g"
    make ${MAKE_OPT} check
    popd >/dev/null
}

function run_quicfuzz {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/seed
    pushd ${HOME}/target/quicfuzz/ngtcp2/ngtcp2 >/dev/null

    mkdir -p $outdir

    # TODO: symbolize=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"

    timeout -s INT -k 1s --preserve-status $timeout \
        ${HOME}/quic-fuzz/aflnet/afl-fuzz \
        -d -i ${indir} -o ${outdir} -N udp://127.0.0.1/4433 \
        -y -m none -P QUIC -q 3 -s 3 -E -K \
        -R ${HOME}/target/quicfuzz/ngtcp2/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        /tmp/server-key.pem /tmp/server-cert.pem --initial-pkt-num=0
        ${HOME}/profuzzbench/cert/server.key \
        ${HOME}/profuzzbench/cert/fullchain.crt --initial-pkt-num=0

    popd >/dev/null
}

function build_asan {
    echo "Not implemented"
}

function build_gcov {
    target_root=${HOME}/target
    unset AFL_USE_ASAN
    export CC=gcc
    export CXX=g++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    export LDFLAGS=""

    mkdir -p "${target_root}/gcov/ngtcp2"
    rm -rf "${target_root}/gcov/ngtcp2"/*
    cp -r ${HOME}/repo/ngtcp2/ngtcp2 "${target_root}/gcov/ngtcp2/"
    cp -r ${HOME}/repo/ngtcp2/wolfssl "${target_root}/gcov/ngtcp2/"
    cp -r ${HOME}/repo/ngtcp2/nghttp3 "${target_root}/gcov/ngtcp2/"

    pushd "${target_root}/gcov/ngtcp2/wolfssl" >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-keylog-export --enable-ech
    make ${MAKE_OPT} && make install
    popd >/dev/null

    pushd "${target_root}/gcov/ngtcp2/nghttp3" >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT} check && make install
    popd >/dev/null

    pushd "${target_root}/gcov/ngtcp2/ngtcp2" >/dev/null
    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"
    git apply ${HOME}/profuzzbench/.trees/ngtcp2/subjects/QUIC/ngtcp2/msquic-ngtcp2-ft-exit.patch || return 1
    autoreconf -i
    export PKG_CONFIG_PATH=${target_root}/gcov/ngtcp2/wolfssl/build/lib/pkgconfig:${target_root}/gcov/ngtcp2/nghttp3/build/lib/pkgconfig
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT}
    if [ ! -x "${PWD}/examples/wsslserver" ]; then
        echo "[!] build_gcov failed: ${PWD}/examples/wsslserver not found"
        popd >/dev/null
        return 1
    fi
    popd >/dev/null
}

function install_dependencies {
    local hp="${HTTP_PROXY:-${http_proxy:-}}"
    local hsp="${HTTPS_PROXY:-${https_proxy:-}}"
    sudo mkdir -p /var/lib/apt/lists/partial
    sudo env http_proxy="${hp}" https_proxy="${hsp}" apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive http_proxy="${hp}" https_proxy="${hsp}" \
        apt-get install -y --no-install-recommends libev-dev
    sudo rm -rf /var/lib/apt/lists/*
}
