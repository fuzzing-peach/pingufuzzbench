#!/usr/bin/env bash

function checkout {
    ngtcp2_baseline="28d3126"
    target_ref="${1:-$ngtcp2_baseline}"

    mkdir -p repo

    if [ ! -d ".git-cache/ngtcp2" ]; then
        git clone --recursive https://github.com/ngtcp2/ngtcp2 .git-cache/ngtcp2
    else
        pushd .git-cache/ngtcp2 >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    cp -r .git-cache/ngtcp2 repo/ngtcp2
    pushd repo/ngtcp2 >/dev/null
    git checkout "${ngtcp2_baseline}"
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/quicfuzz-ngtcp2.patch || return 1
    git add .
    git commit -m "apply quicfuzz-ngtcp2 patch"
    patch_commit=$(git rev-parse HEAD)
    if [ "${target_ref}" != "${ngtcp2_baseline}" ]; then
        git checkout "${target_ref}"
        git cherry-pick "${patch_commit}" || return 1
    fi
    popd >/dev/null

    if [ ! -d ".git-cache/wolfssl" ]; then
        git clone https://github.com/wolfSSL/wolfssl .git-cache/wolfssl
    else
        pushd .git-cache/wolfssl >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    cp -r .git-cache/wolfssl repo/wolfssl
    pushd repo/wolfssl >/dev/null
    git checkout b3f08f3
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/wolfssl-random.patch || return 1
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/wolfssl-time.patch || return 1
    git add .
    git commit -m "apply wolfssl deterministic random/time patches"
    popd >/dev/null

    if [ ! -d ".git-cache/nghttp3" ]; then
        git clone https://github.com/ngtcp2/nghttp3 .git-cache/nghttp3
    fi
    cp -r .git-cache/nghttp3 repo/nghttp3
    pushd repo/nghttp3 >/dev/null
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
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/ngtcp2 target/aflnet/
    cp -r repo/wolfssl target/aflnet/
    cp -r repo/nghttp3 target/aflnet/

    pushd target/aflnet/wolfssl >/dev/null
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

    pushd target/aflnet/nghttp3 >/dev/null
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

    pushd target/aflnet/ngtcp2 >/dev/null
    autoreconf -i
    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    export PKG_CONFIG_PATH=${HOME}/target/aflnet/wolfssl/build/lib/pkgconfig:${HOME}/target/aflnet/nghttp3/build/lib/pkgconfig
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

    pushd ${HOME}/target/aflnet/ngtcp2 >/dev/null

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
        ${HOME}/target/aflnet/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        ${cert_dir}/server.key \
        ${cert_dir}/fullchain.crt --initial-pkt-num=0 || true

    cd ${HOME}/target/gcov/ngtcp2
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    # Resolve relative source paths referenced by crypto/shared.gcda.
    ln -sfn ${HOME}/target/gcov/ngtcp2/crypto/shared.c ${HOME}/target/gcov/ngtcp2/shared.c
    mkdir -p ${HOME}/target/gcov/lib
    if [ ! -e ${HOME}/target/gcov/lib/ngtcp2_macro.h ]; then
        ln -s ${HOME}/target/gcov/ngtcp2/lib/ngtcp2_macro.h ${HOME}/target/gcov/lib/ngtcp2_macro.h
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
    eval "gcovr ${gcov_common_opts} -s -d" >/dev/null 2>&1 || true
    list_cmd="find ${outdir}/replayable-queue -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$cov_cmd" ""
    mkdir -p ${outdir}/cov_html
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/ngtcp2 target/stateafl/
    cp -r repo/wolfssl target/stateafl/
    cp -r repo/nghttp3 target/stateafl/

    pushd target/stateafl/wolfssl >/dev/null
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

    pushd target/stateafl/nghttp3 >/dev/null
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

    pushd target/stateafl/ngtcp2 >/dev/null
    autoreconf -i
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export AFL_USE_ASAN=1
    export CFLAGS="-g -O2 -fsanitize=address"
    export CXXFLAGS="-g -O2 -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    export PKG_CONFIG_PATH=${HOME}/target/stateafl/wolfssl/build/lib/pkgconfig:${HOME}/target/stateafl/nghttp3/build/lib/pkgconfig
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

    pushd ${HOME}/target/stateafl/ngtcp2 >/dev/null

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
        ${HOME}/target/stateafl/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        ${cert_dir}/server.key \
        ${cert_dir}/fullchain.crt --initial-pkt-num=0 || true

    cd ${HOME}/target/gcov/ngtcp2
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    ln -sfn ${HOME}/target/gcov/ngtcp2/crypto/shared.c ${HOME}/target/gcov/ngtcp2/shared.c
    mkdir -p ${HOME}/target/gcov/lib
    if [ ! -e ${HOME}/target/gcov/lib/ngtcp2_macro.h ]; then
        ln -s ${HOME}/target/gcov/ngtcp2/lib/ngtcp2_macro.h ${HOME}/target/gcov/lib/ngtcp2_macro.h
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
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/ngtcp2 target/sgfuzz/ngtcp2
    cp -r repo/wolfssl target/sgfuzz/wolfssl
    cp -r repo/nghttp3 target/sgfuzz/nghttp3

    pushd target/sgfuzz/wolfssl >/dev/null
    unset LLVM_COMPILER
    export CC=clang
    export CXX=clang++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-static --enable-shared=no --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd target/sgfuzz/nghttp3 >/dev/null
    unset LLVM_COMPILER
    export CC=clang
    export CXX=clang++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT}
    make install
    popd >/dev/null

    pushd target/sgfuzz/ngtcp2 >/dev/null
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    export CXXFLAGS="-std=gnu++20 -O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    python3 ${HOME}/sgfuzz/sanitizer/State_machine_instrument.py .
    autoreconf -i
    export PKG_CONFIG_PATH=${HOME}/target/sgfuzz/wolfssl/build/lib/pkgconfig:${HOME}/target/sgfuzz/nghttp3/build/lib/pkgconfig
    # wolfssl is static-only here; ngtcp2's wolfSSL_is_quic link check needs libm.
    export LIBS="-lm"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT}

    pushd examples >/dev/null
    extract-bc wsslserver

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE=${HOME}/target/sgfuzz/ngtcp2/enum_types.txt
    opt -load-pass-plugin=${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so \
        -passes="sgfuzz-source" -debug-pass-manager wsslserver.bc -o wsslserver_opt.bc

    llvm-dis-17 wsslserver_opt.bc -o wsslserver_opt.ll
    sed -i 's/optnone //g;s/optnone//g' wsslserver_opt.ll

    clang wsslserver_opt.ll -o wsslserver \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DSGFUZZ \
        -lsFuzzer \
        -lhfnetdriver \
        -lhfcommon \
        -L${HOME}/target/sgfuzz/ngtcp2/lib/.libs \
        -lngtcp2 \
        -L${HOME}/target/sgfuzz/ngtcp2/crypto/wolfssl/.libs \
        -lngtcp2_crypto_wolfssl \
        -L${HOME}/target/sgfuzz/nghttp3/build/lib \
        -lnghttp3 \
        -L${HOME}/target/sgfuzz/wolfssl/build/lib \
        -lwolfssl \
        -lev \
        -ldl \
        -lm \
        -lz \
        -lpthread \
        -lstdc++

    popd >/dev/null
    rm -rf .git
    popd >/dev/null
}

function run_sgfuzz {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    queue=${outdir}/replayable-queue
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/seed
    cert_dir=${HOME}/profuzzbench/cert

    pushd ${HOME}/target/sgfuzz/ngtcp2/examples >/dev/null

    mkdir -p ${queue}
    rm -rf ${queue}/*
    mkdir -p ${outdir}/crashes
    rm -rf ${outdir}/crashes/*

    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1
    export HFND_TCP_PORT=4433
    export HFND_FORK_MODE=1
    export FAKE_RANDOM=1
    export FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}"

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -shrink=1
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time=${timeout}
        -fork=1
        -artifact_prefix="${outdir}/crashes/"
        "${queue}"
        "${indir}"
    )

    WSSLSERVER_ARGS=(
        127.0.0.1
        4433
        ${cert_dir}/server.key
        ${cert_dir}/fullchain.crt
        --initial-pkt-num=0
    )

    ./wsslserver "${SGFuzz_ARGS[@]}" -- "${WSSLSERVER_ARGS[@]}"

    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${queue}

    cd ${HOME}/target/gcov/ngtcp2
    find . -maxdepth 1 \( -name "a-conftest.gcno" -o -name "a-conftest.gcda" \) -delete || true
    ln -sfn ${HOME}/target/gcov/ngtcp2/crypto/shared.c ${HOME}/target/gcov/ngtcp2/shared.c
    mkdir -p ${HOME}/target/gcov/lib
    if [ ! -e ${HOME}/target/gcov/lib/ngtcp2_macro.h ]; then
        ln -s ${HOME}/target/gcov/ngtcp2/lib/ngtcp2_macro.h ${HOME}/target/gcov/lib/ngtcp2_macro.h
    fi

    function replay {
        timeout -s INT -k 1s 5s ${HOME}/aflnet/afl-replay "$1" NOP 4433 100 &
        LD_PRELOAD=libgcov_preload.so FAKE_RANDOM=1 FAKE_TIME="${FAKE_TIME:-2026-03-11 12:00:00}" \
            timeout -s INT -k 1s 5s ./examples/wsslserver 127.0.0.1 4433 \
            ${cert_dir}/server.key \
            ${cert_dir}/fullchain.crt --initial-pkt-num=0 || true
        wait || true
    }

    gcov_exec="gcov"
    sample_gcno=$(find . -name "*.gcno" -print -quit 2>/dev/null || true)
    if [ -n "${sample_gcno}" ] && gcov-dump "${sample_gcno}" 2>/dev/null | head -n 1 | grep -q "408\\*"; then
        gcov_exec="llvm-cov-17 gcov"
    fi
    gcov_common_opts="--gcov-executable \"${gcov_exec}\" -r ."
    cov_cmd="gcovr ${gcov_common_opts} -s | grep \"[lb][a-z]*:\""
    list_cmd="find ${queue} -maxdepth 1 -type f -name 'id*' | sort | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$cov_cmd" ""

    mkdir -p ${outdir}/cov_html
    eval "gcovr ${gcov_common_opts} --html --html-details -o ${outdir}/cov_html/index.html" || true

    popd >/dev/null
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
    mkdir -p target/quicfuzz
    rm -rf target/quicfuzz/*
    cp -r repo/ngtcp2 target/quicfuzz/
    cp -r repo/wolfssl target/quicfuzz/
    cp -r repo/nghttp3 target/quicfuzz/

    pushd target/quicfuzz/wolfssl >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-harden --enable-ech
    make ${MAKE_OPT} && make install
    popd >/dev/null

    pushd target/quicfuzz/nghttp3 >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT} check && make install
    popd >/dev/null

    pushd target/quicfuzz/ngtcp2 >/dev/null
    autoreconf -i
    export CC=${HOME}/quic-fuzz/aflnet/afl-clang-fast
    export CXX=${HOME}/quic-fuzz/aflnet/afl-clang-fast++
    export PKG_CONFIG_PATH=${HOME}/target/quicfuzz/wolfssl/build/lib/pkgconfig:${HOME}/target/quicfuzz/nghttp3/build/lib/pkgconfig
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
    pushd ${HOME}/target/quicfuzz/ngtcp2 >/dev/null

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
        -R ${HOME}/target/quicfuzz/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        /tmp/server-key.pem /tmp/server-cert.pem --initial-pkt-num=0
        ${HOME}/profuzzbench/cert/server.key \
        ${HOME}/profuzzbench/cert/fullchain.crt --initial-pkt-num=0

    popd >/dev/null
}

function build_asan {
    echo "Not implemented"
}

function build_gcov {
    mkdir -p target/gcov
    rm -rf target/gcov/*
    cp -r repo/ngtcp2 target/gcov/
    cp -r repo/wolfssl target/gcov/
    cp -r repo/nghttp3 target/gcov/

    pushd target/gcov/wolfssl >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-keylog-export --enable-ech
    make ${MAKE_OPT} && make install
    popd >/dev/null

    pushd target/gcov/nghttp3 >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT} check && make install
    popd >/dev/null

    pushd target/gcov/ngtcp2 >/dev/null
    autoreconf -i
    export CC=gcc
    export CXX=g++
    export PKG_CONFIG_PATH=${HOME}/target/gcov/wolfssl/build/lib/pkgconfig:${HOME}/target/gcov/nghttp3/build/lib/pkgconfig
    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT} check
    popd >/dev/null
}

function install_dependencies {
    sudo mkdir -p /var/lib/apt/lists/partial
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libev-dev
    sudo rm -rf /var/lib/apt/lists/*
}
