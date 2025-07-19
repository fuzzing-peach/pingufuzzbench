#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://gitee.com/zzroot/wolfssl.git repo/wolfssl
    pushd repo/wolfssl >/dev/null

    git checkout "$@"
    ./autogen.sh

    popd >/dev/null
}

function replay {
    ${HOME}/aflnet/aflnet-replay $1 TLS 4433 100 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 1s 3s ./examples/server/server \
        -c ${HOME}/profuzzbench/test.fullchain.pem \
        -k ${HOME}/profuzzbench/test.key.pem \
        -e -p 4433
    wait
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/wolfssl target/aflnet/
    pushd target/aflnet/wolfssl >/dev/null

    export CC=$HOME/aflnet/afl-clang-fast
    export AFL_USE_ASAN=1

    ./configure --enable-static --enable-shared=no
    make examples/server/server ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function run_aflnet {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    pushd ${HOME}/target/aflnet/wolfssl >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        $HOME/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 100 -m none \
        ./examples/server/server \
        -c ${HOME}/profuzzbench/test.fullchain.pem \
        -k ${HOME}/profuzzbench/test.key.pem \
        -e -p 4433

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    cov_cmd="gcovr -r . -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/wolfssl

    # clear the gcov data before computing coverage
    gcovr -r . -s -d >/dev/null 2>&1

    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$cov_cmd"
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/wolfssl target/stateafl/wolfssl
    pushd target/stateafl/wolfssl >/dev/null

    export CC=$HOME/stateafl/afl-clang-fast
    export AFL_USE_ASAN=1

    ./configure --enable-static --enable-shared=no
    make examples/server/server ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}


function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    # indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls-replay
    pushd ${HOME}/target/stateafl/wolfssl >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        $HOME/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 100 -m none \
        ./examples/server/server \
        -c ${HOME}/profuzzbench/test.fullchain.pem \
        -k ${HOME}/profuzzbench/test.key.pem \
        -e -p 4433

    
    cd ${HOME}/target/gcov/consumer/wolfssl
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    clean_cmd="rm -f ${HOME}/target/gcov/consumer/wolfssl/build/bin/ACME_STORE/*"
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "" "$clean_cmd"

    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}





function build_sgfuzz {
    echo "Not implemented"
}

function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/wolfssl target/ft/generator/wolfssl
    pushd target/ft/generator/wolfssl >/dev/null

    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O0 -g"
    export CXXFLAGS="-O0 -g"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"

    ./configure --enable-static --enable-shared=no
    make examples/client/client ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function build_ft_consumer {
    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/ft-net.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/wolfssl target/ft/consumer/wolfssl
    pushd target/ft/consumer/wolfssl >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-O3 -g -fsanitize=address"
    export CXXFLAGS="-O3 -g -fsanitize=address"

    ./configure --enable-static --enable-shared=no
    make examples/server/server ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function run_ft {
    timeout=$1
    consumer="WolfSSL"
    generator=${GENERATOR:-$consumer}
    work_dir=/tmp/fuzzing-output
    pushd ${HOME}/target/ft/ >/dev/null

    # synthesize the ft configuration yaml
    # according to the targeted fuzzer and generated
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" -e "s|UID|$(id -u)|g" -e "s|GID|$(id -g)|g" ${HOME}/profuzzbench/ft.yaml >"$temp_file"
    cat "$temp_file" >ft.yaml
    printf "\n" >>ft.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/TLS/${generator}/ft-source.yaml >>ft.yaml
    cat ${HOME}/profuzzbench/subjects/TLS/${consumer}/ft-sink.yaml >>ft.yaml

    # running ft-net
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction --purge ft.yaml fuzz -t ${timeout}s

    # collecting coverage results
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ft.yaml gcov -t 3s
    sudo chmod -R 755 $work_dir
    sudo chown -R $(id -u):$(id -g) $work_dir
    cd ${HOME}/target/gcov/consumer/wolfssl
    grcov --branch --threads 2 -s . -t html . -o ${work_dir}/cov_html

    popd >/dev/null
}

function build_pingu_generator {
    mkdir -p target/pingu/generator
    rm -rf target/pingu/generator/*
    cp -r repo/wolfssl target/pingu/generator/wolfssl
    pushd target/pingu/generator/wolfssl >/dev/null

    # get the whole program bitcode
    # build the whole program using wllvm
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CCAS=wllvm
    export CFLAGS="-g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export CXXFLAGS="-g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export LLVM_BITCODE_GENERATION_FLAGS=""
    ./configure --enable-debug --enable-static --enable-shared=no --enable-session-ticket --enable-tls13 --enable-opensslextra --enable-tlsv12=no
    make examples/client/client ${MAKE_OPT}
    cd examples/client
    extract-bc client

    # now we have client.bc
    # instrument the whole program bitcode
    opt -load-pass-plugin=${HOME}/pingu/pingu-agent/pass/pingu-source-pass.so \
        -passes="pingu-source" -debug-pass-manager \
        -ins=load,store,trampoline -role=source \
        -patchpoint-blacklist=wolfcrypt/src/poly1305.c,wolfcrypt/src/misc.c \
        client.bc -o client_opt.bc

    clang -O0 -lm -L/home/user/pingu/target/debug -Wl,-rpath,${HOME}/pingu/target/debug \
        -lpingu_agent -fsanitize=address \
        client_opt.bc -o client

    rm -rf .git

    popd >/dev/null
}

function build_pingu_consumer {
    mkdir -p target/pingu/consumer
    rm -rf target/pingu/consumer/*
    cp -r repo/wolfssl target/pingu/consumer/wolfssl
    pushd target/pingu/consumer/wolfssl >/dev/null

    # get the whole program bitcode
    # build the whole program using wllvm
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CCAS=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names"
    export LLVM_BITCODE_GENERATION_FLAGS=""
    ./configure --enable-debug --enable-static --enable-shared=no --enable-session-ticket --enable-tls13 --enable-opensslextra --enable-tlsv12=no
    make examples/server/server ${MAKE_OPT}
    cd examples/server
    extract-bc server

    # now we have server.bc
    # instrument the whole program bitcode
    opt -load-pass-plugin=${HOME}/pingu/pingu-agent/pass/pingu-source-pass.so \
        -load-pass-plugin=${HOME}/pingu/pingu-agent/pass/afl-llvm-pass.so \
        -passes="pingu-source,afl-coverage" -debug-pass-manager \
        -ins=load,store -role=sink -svf=0 -dump-svf=0 \
        -patchpoint-blacklist=wolfcrypt/src/poly1305.c,wolfcrypt/src/misc.c \
        server.bc -o server_opt.bc

    clang -O0 -lm -L/home/user/pingu/target/debug -Wl,-rpath,${HOME}/pingu/target/debug \
        -lpingu_agent -fsanitize=address \
        server_opt.bc -o server

    rm -rf .git
    popd >/dev/null
}

function run_pingu {
    timeout=$1
    consumer="WolfSSL"
    generator=${2-$consumer}
    work_dir=/tmp/fuzzing-output
    pushd ${HOME}/target/pingu/ >/dev/null

    # synthesize the pingu configuration yaml
    # according to the targeted fuzzer and generated
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|$work_dir|g" -e "s|UID|$(id -u)|g" -e "s|GID|$(id -g)|g" ${HOME}/profuzzbench/pingu.yaml >"$temp_file"
    cat "$temp_file" >pingu.yaml
    printf "\n" >>pingu.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/TLS/${generator}/pingu-source.yaml >>pingu.yaml
    cat ${HOME}/profuzzbench/subjects/TLS/${consumer}/pingu-sink.yaml >>pingu.yaml

    # running pingu
    sudo timeout ${timeout}s ${HOME}/pingu/target/debug/pingu pingu.yaml -v --purge fuzz

    # collecting coverage results
    sudo ${HOME}/pingu/target/debug/pingu pingu.yaml -v gcov --pcap --purge
    sudo chmod -R 755 $work_dir
    sudo chown -R $(id -u):$(id -g) $work_dir
    cd ${HOME}/target/gcov/consumer/wolfssl
    grcov --branch --threads 2 -s . -t html -o ${work_dir}/cov_html .

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/wolfssl target/gcov/consumer/wolfssl
    pushd target/gcov/consumer/wolfssl >/dev/null

    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export CPPFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"

    ./configure --enable-static --enable-shared=no
    make examples/server/server ${MAKE_OPT}

    rm -rf a-conftest.gcno .git

    popd >/dev/null
}

function install_dependencies {
    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/pingu.conf /etc/ld.so.conf.d/
    sudo ldconfig
}
