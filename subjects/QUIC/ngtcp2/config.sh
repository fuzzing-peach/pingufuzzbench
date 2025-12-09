#!/usr/bin/env bash

function checkout {
    mkdir -p repo

    if [ ! -d ".git-cache/ngtcp2" ]; then
        git clone --recursive https://github.com/ngtcp2/ngtcp2 .git-cache/ngtcp2
    fi
    cp -r .git-cache/ngtcp2 repo/ngtcp2
    pushd repo/ngtcp2 >/dev/null
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/quicfuzz-ngtcp2.patch
    popd >/dev/null

    if [ ! -d ".git-cache/wolfssl" ]; then
        git clone --depth 1 -b v5.7.0-stable https://github.com/wolfSSL/wolfssl .git-cache/wolfssl
    fi
    cp -r .git-cache/wolfssl repo/wolfssl
    pushd repo/wolfssl >/dev/null
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/quicfuzz-wolfssl.patch
    popd >/dev/null

    if [ ! -d ".git-cache/nghttp3" ]; then
        git clone https://github.com/ngtcp2/nghttp3 .git-cache/nghttp3
    fi
    cp -r .git-cache/nghttp3 repo/nghttp3
    pushd repo/nghttp3 >/dev/null
    git checkout 6bcfffb
    git submodule update --init --recursive
    pushd lib/sfparse >/dev/null
    git checkout 6e15726
    popd >/dev/null
    popd >/dev/null
}

function build_aflnet {
    echo "Not implemented"
}

function run_aflnet {
    echo "Not implemented"
}

function build_stateafl {
    echo "Not implemented"
}

function run_stateafl {
    echo "Not implemented"
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
    mkdir -p target/quicfuzz
    rm -rf target/quicfuzz/*
    cp -r repo/ngtcp2 target/quicfuzz/
    cp -r repo/wolfssl target/quicfuzz/
    cp -r repo/nghttp3 target/quicfuzz/

    pushd target/quicfuzz/wolfssl >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-harden --disable-ech
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
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/ngtcp2_seed
    pushd ${HOME}/target/quicfuzz/ngtcp2 >/dev/null

    mkdir -p $outdir

    # TODO: symbolize=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    export AFL_SKIP_CPUFREQ=1
    export AFL_NO_AFFINITY=1

    timeout -k 0 --preserve-status $timeout \
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
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-keylog-export --disable-ech
    make ${MAKE_OPT} && make install
    popd >/dev/null

    pushd target/gcov/nghttp3 >/dev/null
    autoreconf -i
    ./configure --prefix=${PWD}/build --enable-lib-only
    make ${MAKE_OPT} check && make install
    popd >/dev/null

    pushd target/gcov/ngtcp2 >/dev/null
    autoreconf -i
    export CC=clang
    export CXX=clang++
    export PKG_CONFIG_PATH=${HOME}/target/gcov/wolfssl/build/lib/pkgconfig:${HOME}/target/gcov/nghttp3/build/lib/pkgconfig
    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"
    ./configure --with-wolfssl --disable-shared --enable-static
    make ${MAKE_OPT} check
    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}