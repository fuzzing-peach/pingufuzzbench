#!/usr/bin/env bash

function checkout {
    if [ ! -d ".git-cache/openssl" ]; then
        git clone https://github.com/openssl/openssl.git .git-cache/openssl
    fi
    mkdir -p repo
    cp -r .git-cache/openssl repo/openssl
    pushd repo/openssl >/dev/null
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/TLS/OpenSSL/ft-openssl.patch
    popd >/dev/null
}

function replay {
    # the process launching order is confusing.
    ${HOME}/aflnet/aflnet-replay $1 TLS 4433 100 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 1s 3s ./apps/openssl s_server \
        -cert ${HOME}/profuzzbench/cert/server.crt \
        -key ${HOME}/profuzzbench/cert/server.key \
        -CAfile ${HOME}/profuzzbench/cert/ca.crt \
        -accept 4433 -4
    wait
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/openssl target/aflnet/openssl
    pushd target/aflnet/openssl >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    # --with-rand-seed=none only will raise: entropy source strength too weak
    # mentioned by: https://github.com/openssl/openssl/issues/20841
    # see https://github.com/openssl/openssl/blob/master/INSTALL.md#seeding-the-random-generator for selectable options for --with-rand-seed=X
    export CFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom enable-asan no-shared no-threads no-tests no-asm no-cached-fetch no-async
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_aflnet {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    pushd ${HOME}/target/aflnet/openssl >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./apps/openssl s_server \
        -CAfile ${HOME}/profuzzbench/cert/ca.crt \
        -cert ${HOME}/profuzzbench/cert/server.crt \
        -key ${HOME}/profuzzbench/cert/server.key \
        -accept 4433 -4

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    cov_cmd="gcovr -r . -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/openssl
    
    # clear the gcov data before computing coverage
    gcovr -r . -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$cov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/openssl target/stateafl/openssl
    pushd target/stateafl/openssl >/dev/null

    export AFL_SKIP_CPUFREQ=1
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom no-shared no-threads no-tests no-asm no-cached-fetch no-async enable-asan
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_stateafl {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls-replay
    pushd ${HOME}/target/stateafl/openssl >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    # if [ ! -z "${CPU_CORE}" ]; then
    #     fuzzer_args="-b ${CPU_CORE}"
    # fi

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none -t 1000 $fuzzer_args \
        ./apps/openssl s_server \
        -CAfile ${HOME}/profuzzbench/cert/ca.crt \
        -cert ${HOME}/profuzzbench/cert/server.crt \
        -key ${HOME}/profuzzbench/cert/server.key \
        -accept 4433 -4 > /tmp/fuzzing-output/stateafl.log 2>&1

    cd ${HOME}/target/gcov/consumer/openssl
    # clear the gcov data before computing coverage
    gcovr -r . -s -d ${MAKE_OPT} >/dev/null 2>&1

    cov_cmd="gcovr -r . -s ${MAKE_OPT} | grep \"[lb][a-z]*:\""
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"

    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$cov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_sgfuzz {
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/openssl target/sgfuzz/openssl

    pushd $HOME/target/sgfuzz/openssl > /dev/null

    python3 $HOME/sgfuzz/sanitizer/State_machine_instrument.py .

    ./config --with-rand-seed=devrandom -d no-shared no-threads no-tests no-asm enable-asan no-cached-fetch no-async
    sed -i 's@CC=$(CROSS_COMPILE)gcc.*@CC=clang@g' Makefile
    sed -i 's@CXX=$(CROSS_COMPILE)g++.*@CXX=clang++@g' Makefile
    sed -i 's/CFLAGS=.*/CFLAGS=-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ -fsanitize=address -fsanitize=fuzzer-no-link -Wno-int-conversion/g' Makefile
    sed -i 's/CXXFLAGS=.*/CXXFLAGS=-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ -fsanitize=address -fsanitize=fuzzer-no-link -Wno-int-conversion/g' Makefile
    sed -i 's@-Wl,-z,defs@@g' Makefile

    set +e
    make ${MAKE_OPT}
    set -e

    clang -O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ \
        -fsanitize=address -fsanitize=fuzzer -Wno-int-conversion -L.   \
        -o apps/openssl \
        apps/lib/openssl-bin-cmp_mock_srv.o \
        apps/openssl-bin-asn1parse.o apps/openssl-bin-ca.o \
        apps/openssl-bin-ciphers.o apps/openssl-bin-cmp.o \
        apps/openssl-bin-cms.o apps/openssl-bin-crl.o \
        apps/openssl-bin-crl2pkcs7.o apps/openssl-bin-dgst.o \
        apps/openssl-bin-dhparam.o apps/openssl-bin-dsa.o \
        apps/openssl-bin-dsaparam.o apps/openssl-bin-ec.o \
        apps/openssl-bin-ecparam.o apps/openssl-bin-enc.o \
        apps/openssl-bin-engine.o apps/openssl-bin-errstr.o \
        apps/openssl-bin-fipsinstall.o apps/openssl-bin-gendsa.o \
        apps/openssl-bin-genpkey.o apps/openssl-bin-genrsa.o \
        apps/openssl-bin-info.o apps/openssl-bin-kdf.o \
        apps/openssl-bin-list.o apps/openssl-bin-mac.o \
        apps/openssl-bin-nseq.o apps/openssl-bin-ocsp.o \
        apps/openssl-bin-openssl.o apps/openssl-bin-passwd.o \
        apps/openssl-bin-pkcs12.o apps/openssl-bin-pkcs7.o \
        apps/openssl-bin-pkcs8.o apps/openssl-bin-pkey.o \
        apps/openssl-bin-pkeyparam.o apps/openssl-bin-pkeyutl.o \
        apps/openssl-bin-prime.o apps/openssl-bin-progs.o \
        apps/openssl-bin-rand.o apps/openssl-bin-rehash.o \
        apps/openssl-bin-req.o apps/openssl-bin-rsa.o \
        apps/openssl-bin-rsautl.o apps/openssl-bin-s_client.o \
        apps/openssl-bin-s_server.o apps/openssl-bin-s_time.o \
        apps/openssl-bin-sess_id.o apps/openssl-bin-smime.o \
        apps/openssl-bin-speed.o apps/openssl-bin-spkac.o \
        apps/openssl-bin-srp.o apps/openssl-bin-storeutl.o \
        apps/openssl-bin-ts.o apps/openssl-bin-verify.o \
        apps/openssl-bin-version.o apps/openssl-bin-x509.o \
        apps/libapps.a -lssl -lcrypto -ldl -lsFuzzer -lhfnetdriver -lhfcommon -lstdc++

    rm -rf fuzz test .git doc
    popd > /dev/null
}

function run_sgfuzz {
    timeout=$1
    outdir=/tmp/fuzzing-output
    queue=${outdir}/replayable-queue
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    pushd ${HOME}/target/sgfuzz/openssl >/dev/null

    export HFND_TCP_PORT=4433
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    mkdir -p $queue
    rm -rf $queue/*

    SGFuzz_ARGS=(
        -max_total_time=$timeout
        -close_fd_mask=3
        -shrink=1
        -print_full_coverage=1
        -check_input_sha1=1
        -reduce_inputs=1
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        "${queue}"
        "${indir}"
    )

    OPENSSL_ARGS=(
        s_server
        -CAfile ${HOME}/profuzzbench/cert/ca.crt \
        -key "${HOME}/profuzzbench/cert/server.key"
        -cert "${HOME}/profuzzbench/cert/server.crt"
        -accept "4433"
        -4
    )

    # timeout -k 0 --preserve-status $timeout ./apps/openssl "${SGFuzz_ARGS[@]}" -- "${OPENSSL_ARGS[@]}"
    ./apps/openssl "${SGFuzz_ARGS[@]}" -- "${OPENSSL_ARGS[@]}"
    
    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${queue}
    cov_cmd="gcovr -r . -s ${MAKE_OPT} | grep \"[lb][a-z]*:\""
    list_cmd="ls -1 ${queue}/* | tr '\n' ' ' | sed 's/ $//'"
    cd ${HOME}/target/gcov/consumer/openssl

    # sgfuzz 产生的 testcase 的文件内容不符合 aflnet-replay 的格式要求（4字节的长度前缀）
    # 所以需要单独提供 replay 函数，用 afl-replay 来一次性将 testcase 的所有内容都发出去
    function replay {
        # the process launching order is confusing.
        ${HOME}/aflnet/afl-replay $1 TLS 4433 100 &
        LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
            timeout -k 1s 3s ./apps/openssl s_server \
            -cert ${HOME}/profuzzbench/cert/server.crt \
            -key ${HOME}/profuzzbench/cert/server.key \
            -CAfile ${HOME}/profuzzbench/cert/ca.crt \
            -accept 4433 -4
        wait
    }

    gcovr -r . -s -d ${MAKE_OPT} >/dev/null 2>&1
    # 10 是 step 参数，表示每 10 个 testcase 计算一次覆盖率
    # 因为 sgfuzz（libfuzzer） 产生的 testcase 数量很多，如果每 1 个都计算一次覆盖率，时间开销会很大
    # 每个 testcase 都是 replay 的，但是每 10 个 testcase 统计一下覆盖率
    compute_coverage replay "$list_cmd" 10 ${outdir}/coverage.csv "$cov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details ${MAKE_OPT} -o ${outdir}/cov_html/index.html
    
    popd >/dev/null
}

function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/openssl target/ft/generator/openssl
    pushd target/ft/generator/openssl >/dev/null

    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O3 -g -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -DFT_GENERATOR"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"

    ./config --with-rand-seed=devrandom no-shared no-tests no-threads no-asm no-cached-fetch no-async
    LDCMD=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function build_ft_consumer {
    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/ft-net.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/openssl target/ft/consumer/openssl
    pushd target/ft/consumer/openssl >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom enable-asan no-shared no-tests no-threads no-asm no-cached-fetch no-async
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_ft {
    timeout=$1
    replay_step=$2
    gcov_step=$3
    consumer="OpenSSL"
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
    cd ${HOME}/target/gcov/consumer/openssl
    grcov --branch --threads 4 -s . -t html . -o ${work_dir}/cov_html
    popd >/dev/null
}

function build_pingu_generator {
    mkdir -p target/pingu/generator
    rm -rf target/pingu/generator/*
    cp -r repo/openssl target/pingu/generator/openssl
    pushd target/pingu/generator/openssl >/dev/null

    export FT_HOOK_INS=load,store
    export CC=${HOME}/pingu/fuzztruction/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/pingu/fuzztruction/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
    export GENERATOR_AGENT_SO_DIR="${HOME}/pingu/fuzztruction/target/debug/"
    export LLVM_PASS_SO="${HOME}/pingu/fuzztruction/generator/pass/fuzztruction-source-llvm-pass.so"

    ./config --with-rand-seed=devrandom no-shared no-tests no-threads no-asm no-cached-fetch no-async
    make ${MAKE_OPT}

    # rm -rf fuzz test .git doc

    popd >/dev/null
}

function build_pingu_consumer {

    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/pingu.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/pingu/consumer
    rm -rf target/pingu/consumer/*
    cp -r repo/openssl target/pingu/consumer/openssl
    pushd target/pingu/consumer/openssl >/dev/null

    export CC="${HOME}/pingu/target/debug/libafl_cc"
    export CXX="${HOME}/pingu/target/debug/libafl_cxx"
    export CFLAGS="-O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom enable-asan no-shared no-tests no-threads no-asm no-cached-fetch no-async
    make ${MAKE_OPT}

    # rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_pingu {
    timeout=$1
    consumer="OpenSSL"
    generator=${@: -1}
    generator=${generator:-$consumer}
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
    cd ${HOME}/target/gcov/consumer/openssl
    grcov --branch --threads 2 -s . -t html -o ${work_dir}/cov_html .

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/openssl target/gcov/consumer/openssl
    pushd target/gcov/consumer/openssl >/dev/null

    export CFLAGS="-fprofile-arcs -ftest-coverage -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"

    ./config --with-rand-seed=devrandom no-shared no-threads no-tests no-asm no-cached-fetch no-async
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}

function cleanup_artifacts {
    echo "No artifacts"
}
