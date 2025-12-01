#!/usr/bin/env bash

function checkout {
    mkdir -p repo

    git clone --recursive https://github.com/ngtcp2/ngtcp2 repo/ngtcp2
    pushd repo/ngtcp2 >/dev/null
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/quicfuzz-ngtcp2.patch
    popd >/dev/null

    git clone --depth 1 -b v5.7.0-stable https://github.com/wolfSSL/wolfssl repo/wolfssl
    pushd repo/wolfssl >/dev/null
    git apply ${HOME}/profuzzbench/subjects/QUIC/ngtcp2/quicfuzz-wolfssl.patch
    popd >/dev/null

    git clone https://github.com/ngtcp2/nghttp3 repo/nghttp3
    pushd repo/nghttp3 >/dev/null
    git checkout 7ca2b33423f4e706d540df780c7a1557affdc42c
    git submodule update --init --recursive
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
    ./configure --prefix=${PWD}/build --enable-all --enable-aesni --enable-keylog-export --disable-ech
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
    export CFLAGS="-fsanitize=address"
    export CXXFLAGS="-fsanitize=address" 
    export LDFLAGS="-fsanitize=address" 
    make ${MAKE_OPT} check
    popd >/dev/null
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
    export CC=${HOME}/quic-fuzz/aflnet/afl-clang-fast
    export CXX=${HOME}/quic-fuzz/aflnet/afl-clang-fast++
    export PKG_CONFIG_PATH=${HOME}/target/quicfuzz/wolfssl/build/lib/pkgconfig:${HOME}/target/quicfuzz/nghttp3/build/lib/pkgconfig
    ./configure --with-wolfssl --disable-shared --enable-static
    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage" 
    export LDFLAGS="-fprofile-arcs -ftest-coverage" 
    make ${MAKE_OPT} check
    popd >/dev/null
}

function run_quicfuzz {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/QUIC/ngtcp2/in-quic
    pushd ${HOME}/target/quicfuzz/ngtcp2/build/bin >/dev/null

    mkdir -p $outdir

    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    # setsid ./run_common.sh ngtcp2 10 ../results/ quic-fuzz/aflnet out-ngtcp2-quic-fuzz '-a /tmp/quic-fuzz/aflnet/sabre -A /tmp/quic-fuzz/aflnet/libsnapfuzz.so -p 0 -y -m none -P QUIC -q 3 -s 3 -E -K' 86400 5 1 > ngtcp2_quic_snap_aflnet.log 2>&1 &
    timeout -k 0 --preserve-status $timeout \
        ${HOME}/quic-fuzz/aflnet/afl-fuzz \
        -d -i ${indir} -o ${outdir} -N udp://127.0.0.1/4433 \
        -a /tmp/quic-fuzz/aflnet/sabre \
        -A /tmp/quic-fuzz/aflnet/libsnapfuzz.so \
        -p 0 -y -m none -P QUIC -q 3 -s 3 -E -K \
        -R /tmp/ngtcp2/examples/wsslserver 127.0.0.1 4433 \
        ${HOME}/profuzzbench/test.key.pem \
        ${HOME}/profuzzbench/test.fullchain.pem --initial-pkt-num=0

}

function install_dependencies {
    echo "No dependencies"
}