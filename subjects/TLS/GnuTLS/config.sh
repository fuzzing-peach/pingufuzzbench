#!/usr/bin/env bash

function checkout {
    if [ ! -d ".git-cache/gnutls" ]; then
        git clone https://gitee.com/kherrisan/gnutls.git .git-cache/gnutls
    fi
    mkdir -p repo
    cp -r .git-cache/gnutls repo/gnutls
    pushd repo/gnutls >/dev/null
    # Check if the checkout changed the commit
    current_commit=$(git rev-parse HEAD)
    echo "Checkout will result in a different commit than requested."
    echo "Requested: $@"
    echo "Current: ${current_commit:0:8}"
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/TLS/GnuTLS/fuzzing.patch
    ./bootstrap
    popd >/dev/null
}

function replay {
    ${HOME}/aflnet/aflnet-replay $1 TLS 5555 100 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 1s 3s ./src/gnutls-serv \
        -a -d 1000 --earlydata \
        --x509certfile=${HOME}/profuzzbench/test.fullchain.pem \
        --x509keyfile=${HOME}/profuzzbench/test.key.pem \
        -b -p 5555
    wait
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/gnutls target/aflnet/gnutls
    pushd target/aflnet/gnutls >/dev/null

    export AFL_USE_ASAN=1
    export ASAN_OPTIONS=detect_leaks=0
    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export CFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    ./configure --enable-static --enable-shared=no
    make -j ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls

    pushd ${HOME}/target/aflnet/gnutls >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5555 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 100 -m none \
        ./src/gnutls-serv \
        -a -d 1000 --earlydata \
        --x509certfile=${HOME}/profuzzbench/test.fullchain.pem \
        --x509keyfile=${HOME}/profuzzbench/test.key.pem \
        -b -p 5555

    cd ${HOME}/target/gcov/consumer/gnutls
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv ""

    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/gnutls target/stateafl/gnutls
    pushd target/stateafl/gnutls >/dev/null

    export ASAN_OPTIONS=detect_leaks=0
    export CC=$HOME/stateafl/afl-clang-fast
    export CXX=$HOME/stateafl/afl-clang-fast++
    export CFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    ./configure --enable-static --enable-shared=no
    make -j ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls-replay
    pushd ${HOME}/target/stateafl/gnutls >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        $HOME/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5555 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 100 -m none \
        ./src/gnutls-serv \
        -a -d 1000 --earlydata \
        --x509certfile=${HOME}/profuzzbench/test.fullchain.pem \
        --x509keyfile=${HOME}/profuzzbench/test.key.pem \
        -b -p 5555
    
    cd ${HOME}/target/gcov/consumer/gnutls
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    # clean_cmd="rm -f ${HOME}/target/gcov/consumer/gnutls/build/bin/ACME_STORE/*"
    # compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "" "$clean_cmd"

    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv ""

    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}


function build_sgfuzz {
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/gnutls target/sgfuzz/gnutls
    pushd target/sgfuzz/gnutls >/dev/null

    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ -v -Wno-int-conversion"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ -v -Wno-int-conversion"

    python3 $HOME/sgfuzz/sanitizer/State_machine_instrument.py .

    ./configure --enable-static --enable-shared=no --disable-tests --disable-doc --disable-fips140
    make ${MAKE_OPT}

    pushd src >/dev/null
    extract-bc gnutls-serv

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE=${HOME}/target/sgfuzz/gnutls/enum_types.txt
    opt -load-pass-plugin=${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so \
        -passes="sgfuzz-source" -debug-pass-manager gnutls-serv.bc -o gnutls-serv_opt.bc

    llvm-dis-17 gnutls-serv_opt.bc -o gnutls-serv_opt.ll
    sed -i 's/optnone //g' gnutls-serv_opt.ll

    clang gnutls-serv_opt.ll -o gnutls-serv \
        -Wl,--no-whole-archive ../lib/.libs/libgnutls.a \
        -lsFuzzer -lhfnetdriver -lhfcommon -lstdc++ \
        -fsanitize=address -fsanitize=fuzzer \
        -lzstd -lz -lp11-kit -lidn2 -lunistring -ldl -ltasn1 -lnettle -lhogweed -lgmp -lpthread -lrt -lm -ldl -lresolv -lc -lgcc -lgcc_s 

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
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls

    pushd ${HOME}/target/sgfuzz/gnutls/src >/dev/null

    mkdir -p $queue
    rm -rf $queue/*
    mkdir -p ${outdir}/crash
    rm -rf ${outdir}/crash/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export HFND_TCP_PORT=5555
    export HFND_FORK_MODE=1

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -shrink=1
        -reduce_inputs=1
        -reload=30
        -fork=1
        -print_full_coverage=1
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time=$timeout
        -artifact_prefix="${outdir}/crash/"
        "${queue}"
        "${indir}"
    )

    GNUTLS_ARGS=(
        -a
        -d 1000
        --earlydata
        --x509certfile=${HOME}/profuzzbench/test.fullchain.pem
        --x509keyfile=${HOME}/profuzzbench/test.key.pem
        -b
        -p 5555
    )

    ./gnutls-serv "${SGFuzz_ARGS[@]}" -- "${GNUTLS_ARGS[@]}"

    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${queue}

    list_cmd="ls -1 ${queue}/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    cd ${HOME}/target/gcov/consumer/gnutls

    function replay {
        ${HOME}/aflnet/afl-replay $1 TLS 5555 100 &
        LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
            timeout -k 1s 3s ./src/gnutls-serv \
            -a -d 1000 --earlydata \
            --x509certfile=${HOME}/profuzzbench/test.fullchain.pem \
            --x509keyfile=${HOME}/profuzzbench/test.key.pem \
            -b -p 5555
        wait
    }

    gcovr -r . -s -d >/dev/null 2>&1
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv ""

    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/gnutls target/ft/generator/gnutls
    pushd target/ft/generator/gnutls >/dev/null

    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-g -O3 -DNDEBUG -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-g -O3 -DNDEBUG -DFT_FUZZING -DFT_GENERATOR"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"

    ./configure --disable-tests --disable-doc --disable-shared
    make ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function build_ft_consumer {
    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/ft-net.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/gnutls target/ft/consumer/gnutls
    pushd target/ft/consumer/gnutls >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"

    ./configure --disable-tests --disable-doc --disable-shared
    make ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function run_ft {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    consumer="GnuTLS"
    generator=${GENERATOR:-$consumer}
    ts=$(date +%s)
    work_dir=/tmp/fuzzing-output
    pushd ${HOME}/target/ft/ >/dev/null

    # synthesize the ft configuration yaml
    # according to the targeted fuzzer and generated
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" -e "s|UID|$(id -u)|g" -e "s|GID|$(id -g)|g" ${HOME}/profuzzbench/ft.yaml >"$temp_file"
    cat "$temp_file" >ft-gnutls.yaml
    printf "\n" >>ft-gnutls.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/TLS/${generator}/ft-source.yaml >>ft-gnutls.yaml
    printf "\n" >>ft-gnutls.yaml
    cat ${HOME}/profuzzbench/subjects/TLS/${consumer}/ft-sink.yaml >>ft-gnutls.yaml

    # running ft-net
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction \
        --purge ft-gnutls.yaml fuzz \
        -t ${timeout}s

    # collecting coverage results
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ft-gnutls.yaml gcov \
        -t 3s --delete \
        --replay-step ${replay_step} --gcov-step ${gcov_step}
    sudo chmod -R 755 $work_dir
    sudo chown -R $(id -u):$(id -g) $work_dir
    cd ${HOME}/target/gcov/consumer/gnutls
    gcovr -r . --html --html-details -o index.html
    mkdir -p ${work_dir}/cov_html
    cp *.html ${work_dir}/cov_html

    popd >/dev/null
}

function build_pingu_generator {
    exit 1

    mkdir -p target/pingu/generator
    rm -rf target/pingu/generator/*
    cp -r repo/wolfssl target/pingu/generator/wolfssl
    pushd target/pingu/generator/wolfssl >/dev/null

    export FT_HOOK_INS=load,store
    export CC=${HOME}/pingu/fuzztruction/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/pingu/fuzztruction/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O2 -g"
    export CXXFLAGS="-O2 -g"
    export GENERATOR_AGENT_SO_DIR="${HOME}/pingu/fuzztruction/target/debug/"
    export LLVM_PASS_SO="${HOME}/pingu/fuzztruction/generator/pass/fuzztruction-source-llvm-pass.so"

    ./autogen.sh
    ./configure --enable-static --enable-shared=no
    make examples/client/client ${MAKE_OPT}

    rm -rf .git

    popd >/dev/null
}

function build_pingu_consumer {
    exit 1

    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/pingu.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/pingu/consumer
    rm -rf target/pingu/consumer/*
    cp -r repo/wolfssl target/pingu/consumer/wolfssl
    pushd target/pingu/consumer/wolfssl >/dev/null

    export CC="${HOME}/pingu/target/debug/libafl_cc"
    export CXX="${HOME}/pingu/target/debug/libafl_cxx"
    export CFLAGS="-O3 -g -fsanitize=address"
    export CXXFLAGS="-O3 -g -fsanitize=address"

    ./autogen.sh
    ./configure --enable-static --enable-shared=no
    make examples/server/server ${MAKE_OPT}

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
    grcov --threads 2 -s . -t html -o ${work_dir}/cov_html .

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/gnutls target/gcov/consumer/gnutls
    pushd target/gcov/consumer/gnutls >/dev/null

    export CFLAGS="${CFLAGS} -fprofile-arcs -ftest-coverage"
    export CXXFLAGS="${CXXFLAGS} -fprofile-arcs -ftest-coverage"
    export LDFLAGS="${LDFLAGS} -fprofile-arcs -ftest-coverage"

    ./configure --enable-code-coverage --disable-tests --disable-doc --disable-shared
    make ${MAKE_OPT}

    rm -rf .git a-conftest.gcno

    popd >/dev/null
}

function install_dependencies {
    sudo -E apt update
    sudo -E apt install -y dash git-core autoconf libtool gettext autopoint lcov \
                            nettle-dev libp11-kit-dev libtspi-dev libunistring-dev \
                            libtasn1-bin libtasn1-6-dev libidn2-0-dev gawk gperf \
                            libtss2-dev libunbound-dev dns-root-data bison gtk-doc-tools \
                            libprotobuf-c1 libev4 libev-dev libzstd-dev
    # sudo apt-get install -y texinfo texlive texlive-plain-generic texlive-extra-utils
}
