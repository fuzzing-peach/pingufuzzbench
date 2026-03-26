#!/usr/bin/env bash

OPENSSL_ECH_BRANCH="feature/ech"
OPENSSL_ECH_BASELINE="d01cd520e52ab8bcdad27496209a27022679d970"
OPENSSL_REDUCED_FEATURE_FLAGS="no-legacy no-deprecated no-ct no-nextprotoneg no-srp no-ts no-cmp no-cms"

function get_ech_config_list {
    ech_pem="$1"
    openssl_bin="$2"
    if [ ! -f "${ech_pem}" ]; then
        return 1
    fi
    if [ ! -x "${openssl_bin}" ]; then
        return 1
    fi
    # s_client -ech_config_list expects base64-encoded ECHConfigList.
    awk '/BEGIN ECHCONFIG/{f=1;next}/END ECHCONFIG/{f=0}f' "${ech_pem}" | tr -d '\n'
}

function checkout {
    target_ref="${1:-$OPENSSL_ECH_BASELINE}"
    cache_repo=".git-cache/openssl"
    work_repo="repo/openssl"

    if [ ! -d "${cache_repo}/.git" ]; then
        git clone --no-single-branch https://github.com/openssl/openssl.git "${cache_repo}"
    fi

    pushd "${cache_repo}" >/dev/null
    git fetch --prune origin "${OPENSSL_ECH_BRANCH}"
    git reset --hard
    git clean -fdx
    popd >/dev/null

    mkdir -p repo
    rm -rf "${work_repo}"
    git clone --no-hardlinks "${cache_repo}" "${work_repo}"

    pushd "${work_repo}" >/dev/null

    git checkout "${OPENSSL_ECH_BASELINE}"
    git apply "${HOME}/profuzzbench/subjects/TLS/OpenSSL/ft-openssl.patch"
    git add .
    git commit -m "apply fuzzing patch"
    patch_commit=$(git rev-parse HEAD)

    if [ "$target_ref" != "$OPENSSL_ECH_BASELINE" ]; then
        git checkout "$target_ref"
        git cherry-pick "$patch_commit"
    fi

    popd >/dev/null
}

function replay {
    # the process launching order is confusing.
    cert_dir=${HOME}/profuzzbench/cert
    ${HOME}/aflnet/aflnet-replay $1 TLS 4433 100 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 1s 3s ./apps/openssl s_server \
        -tls1_3 \
        -key ${cert_dir}/server.key \
        -cert ${cert_dir}/server.crt \
        -CAfile ${cert_dir}/ca.crt \
        -ech_key ${cert_dir}/echconfig.pem \
        -alpn h2,http/1.1 \
        -status \
        -status_file ${cert_dir}/ocsp.der \
        -num_tickets 4 \
        -accept 4433 \
        -naccept 1 \
        -4
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
    # -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION is removed
    export CFLAGS="-O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom enable-asan no-shared no-threads no-tests no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    cert_dir=${HOME}/profuzzbench/cert
    ech_config_list=$(get_ech_config_list "${cert_dir}/echconfig.pem" "${HOME}/target/aflnet/openssl/apps/openssl" || true)
    pushd ${HOME}/target/aflnet/openssl >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    OPENSSL_ECH_CONFIG_LIST="${ech_config_list}" timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./apps/openssl s_server \
        -tls1_3 \
        -key ${cert_dir}/server.key \
        -cert ${cert_dir}/server.crt \
        -CAfile ${cert_dir}/ca.crt \
        -ech_key ${cert_dir}/echconfig.pem \
        -alpn h2,http/1.1 \
        -status \
        -status_file ${cert_dir}/ocsp.der \
        -num_tickets 4 \
        -accept 4433 \
        -naccept 1 \
        -4

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
    export CFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom no-shared no-threads no-tests no-asm no-cached-fetch no-async enable-asan ${OPENSSL_REDUCED_FEATURE_FLAGS}
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls-replay
    cert_dir=${HOME}/profuzzbench/cert
    ech_config_list=$(get_ech_config_list "${cert_dir}/echconfig.pem" "${HOME}/target/stateafl/openssl/apps/openssl" || true)
    pushd ${HOME}/target/stateafl/openssl >/dev/null

    mkdir -p $outdir

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    # if [ ! -z "${CPU_CORE}" ]; then
    #     fuzzer_args="-b ${CPU_CORE}"
    # fi

    OPENSSL_ECH_CONFIG_LIST="${ech_config_list}" timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none -t 3000 $fuzzer_args \
        ./apps/openssl s_server \
        -tls1_3 \
        -key ${cert_dir}/server.key \
        -cert ${cert_dir}/server.crt \
        -CAfile ${cert_dir}/ca.crt \
        -ech_key ${cert_dir}/echconfig.pem \
        -alpn h2,http/1.1 \
        -status \
        -status_file ${cert_dir}/ocsp.der \
        -num_tickets 4 \
        -accept 4433 \
        -naccept 1 \
        -4 > /tmp/fuzzing-output/stateafl.log 2>&1

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

    ./config --with-rand-seed=devrandom -d no-shared no-threads no-tests no-asm enable-asan no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    sed -i 's@CC=$(CROSS_COMPILE)gcc.*@CC=clang@g' Makefile
    sed -i 's@CXX=$(CROSS_COMPILE)g++.*@CXX=clang++@g' Makefile
    sed -i 's/CFLAGS=.*/CFLAGS=-O3 -g -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ -fsanitize=address -fsanitize=fuzzer-no-link -Wno-int-conversion/g' Makefile
    sed -i 's/CXXFLAGS=.*/CXXFLAGS=-O3 -g -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ -fsanitize=address -fsanitize=fuzzer-no-link -Wno-int-conversion/g' Makefile
    sed -i 's@-Wl,-z,defs@@g' Makefile

    set +e
    make ${MAKE_OPT}
    set -e

    clang -O3 -g -DFT_FUZZING -DFT_CONSUMER -DSGFUZZ \
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
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    queue=${outdir}/replayable-queue
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    cert_dir=${HOME}/profuzzbench/cert
    ech_config_list=$(get_ech_config_list "${cert_dir}/echconfig.pem" "${HOME}/target/sgfuzz/openssl/apps/openssl" || true)
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
        -tls1_3
        -key "${cert_dir}/server.key"
        -cert "${cert_dir}/server.crt"
        -CAfile "${cert_dir}/ca.crt"
        -ech_key "${cert_dir}/echconfig.pem"
        -alpn "h2,http/1.1"
        -status
        -status_file "${cert_dir}/ocsp.der"
        -num_tickets "4"
        -accept "4433"
        -naccept "1"
        -4
    )

    # timeout -k 0 --preserve-status $timeout ./apps/openssl "${SGFuzz_ARGS[@]}" -- "${OPENSSL_ARGS[@]}"
    OPENSSL_ECH_CONFIG_LIST="${ech_config_list}" ./apps/openssl "${SGFuzz_ARGS[@]}" -- "${OPENSSL_ARGS[@]}"
    
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
            -tls1_3 \
            -key ${cert_dir}/server.key \
            -cert ${cert_dir}/server.crt \
            -CAfile ${cert_dir}/ca.crt \
            -ech_key ${cert_dir}/echconfig.pem \
            -alpn h2,http/1.1 \
            -status \
            -status_file ${cert_dir}/ocsp.der \
            -num_tickets 4 \
            -accept 4433 \
            -naccept 1 \
            -4
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

    ./config --with-rand-seed=devrandom no-shared no-tests no-threads no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
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
    export CFLAGS="-O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -DFT_CONSUMER"

    ./config --with-rand-seed=devrandom enable-asan no-shared no-tests no-threads no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_ft {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    consumer="OpenSSL"
    generator=${GENERATOR:-$consumer}
    work_dir=/tmp/fuzzing-output
    cert_dir=${HOME}/profuzzbench/cert
    ech_config_list=$(get_ech_config_list "${cert_dir}/echconfig.pem" "${HOME}/target/ft/generator/openssl/apps/openssl")
    pushd ${HOME}/target/ft/ >/dev/null

    # synthesize the ft configuration yaml
    # according to the targeted fuzzer and generated
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" -e "s|UID|$(id -u)|g" -e "s|GID|$(id -g)|g" ${HOME}/profuzzbench/ft-common.yaml >"$temp_file"
    cat "$temp_file" >ft.yaml
    printf "\n" >>ft.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/TLS/${generator}/ft-source.yaml >>ft.yaml
    cat ${HOME}/profuzzbench/subjects/TLS/${consumer}/ft-sink.yaml >>ft.yaml
    sed -i "s|__ECH_CONFIG_LIST__|${ech_config_list}|g" ft.yaml

    # running ft-net
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction --purge ft.yaml fuzz -t ${timeout}s

    # collecting coverage results
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ft.yaml gcov -t 3s --replay-step ${replay_step} --gcov-step ${gcov_step}
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

    local source_pass_so="${HOME}/pingu/pingu-agent/pass/build/pingu-source-pass.so"
    local extapi_bc="${HOME}/pingu/pingu-agent/pass/build/extapi.bc"
    if [ ! -f "${source_pass_so}" ] || [ ! -f "${extapi_bc}" ]; then
        echo "[!] Missing pingu source pass dependencies: ${source_pass_so}, ${extapi_bc}"
        return 1
    fi

    # Build OpenSSL with wllvm so we can extract whole-program bitcode.
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CCAS=wllvm
    export CFLAGS="-O3 -g -fno-discard-value-names"
    export CXXFLAGS="-O3 -g -fno-discard-value-names"
    export LLVM_BITCODE_GENERATION_FLAGS=""

    ./config --with-rand-seed=devrandom -d no-shared no-tests no-threads no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    rm -f compile_commands.json
    bear --output compile_commands.json -- make ${MAKE_OPT}

    cd apps
    extract-bc openssl

    # Instrument generator (source role) at bitcode level.
    opt -load-pass-plugin="${source_pass_so}" \
        -passes="function(mem2reg,instcombine),pingu-source" -debug-pass-manager \
        -ins=load,store,call,memcpy,trampoline,ret,icmp,memcmp -role=source -svf=1 -dump-svf=0 \
        -extapi-path="${extapi_bc}" \
        openssl.bc -o openssl_opt.bc

    llvm-dis openssl_opt.bc -o openssl_opt.ll
    sed -i 's/optnone //g' openssl_opt.ll

    clang -O0 -L"${HOME}/pingu/target/release" -Wl,-rpath,"${HOME}/pingu/target/release" \
        -lpingu_agent -fsanitize=address \
        openssl_opt.ll -o openssl \
        -lssl -lcrypto -ldl -lz -lstdc++

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function build_pingu_consumer {

    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/pingu.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/pingu/consumer
    rm -rf target/pingu/consumer/*
    cp -r repo/openssl target/pingu/consumer/openssl
    pushd target/pingu/consumer/openssl >/dev/null

    local source_pass_so="${HOME}/pingu/pingu-agent/pass/build/pingu-source-pass.so"
    local afl_pass_so="${HOME}/pingu/pingu-agent/pass/build/afl-llvm-pass.so"
    local extapi_bc="${HOME}/pingu/pingu-agent/pass/build/extapi.bc"
    if [ ! -f "${source_pass_so}" ] || [ ! -f "${afl_pass_so}" ] || [ ! -f "${extapi_bc}" ]; then
        echo "[!] Missing pingu consumer pass dependencies: ${source_pass_so}, ${afl_pass_so}, ${extapi_bc}"
        return 1
    fi

    # Build OpenSSL with wllvm so sink can be instrumented from bitcode.
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CCAS=wllvm
    export CFLAGS="-O3 -g -fno-discard-value-names"
    export CXXFLAGS="-O3 -g -fno-discard-value-names"
    export LLVM_BITCODE_GENERATION_FLAGS=""

    ./config --with-rand-seed=devrandom -d no-shared no-tests no-threads no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    rm -f compile_commands.json
    bear --output compile_commands.json -- make ${MAKE_OPT}

    cd apps
    extract-bc openssl

    # Instrument consumer (sink role) and inject AFL-style coverage.
    opt -load-pass-plugin="${source_pass_so}" \
        -load-pass-plugin="${afl_pass_so}" \
        -passes="function(mem2reg,instcombine),pingu-source,afl-coverage" -debug-pass-manager \
        -ins=load,store,call,memcpy,icmp,memcmp,ret -role=sink -svf=1 -dump-svf=0 \
        -extapi-path="${extapi_bc}" \
        openssl.bc -o openssl_opt.bc

    llvm-dis openssl_opt.bc -o openssl_opt.ll
    sed -i 's/optnone //g' openssl_opt.ll

    clang -O0 -L"${HOME}/pingu/target/release" -Wl,-rpath,"${HOME}/pingu/target/release" \
        -lpingu_agent -fsanitize=address \
        openssl_opt.ll -o openssl \
        -lssl -lcrypto -ldl -lz -lstdc++

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_pingu {
    local replay_step="${1:-1}"
    local gcov_step="${2:-1}"
    local timeout="${3:-300}"
    local consumer="OpenSSL"
    local work_dir=/tmp/fuzzing-output
    local pingu_bin=${HOME}/pingu/target/release/pingu

    if ! [[ "${replay_step}" =~ ^[0-9]+$ ]] || ! [[ "${gcov_step}" =~ ^[0-9]+$ ]] || ! [[ "${timeout}" =~ ^[0-9]+$ ]]; then
        echo "[!] run_pingu expects: replay_step gcov_step timeout"
        return 1
    fi
    if [ ! -x "${pingu_bin}" ]; then
        echo "[!] Missing pingu binary: ${pingu_bin}"
        return 1
    fi
    pushd ${HOME}/target/pingu/ >/dev/null

    # Use merged target-local template directly.
    local pingu_cfg_template=${HOME}/profuzzbench/subjects/TLS/${consumer}/pingu.yaml
    if [ ! -f "${pingu_cfg_template}" ]; then
        echo "[!] Missing merged pingu config: ${pingu_cfg_template}"
        return 1
    fi
    if ! grep -q '^[[:space:]]*target:' "${pingu_cfg_template}"; then
        echo "[!] Invalid pingu config (missing required 'target' field): ${pingu_cfg_template}"
        return 1
    fi
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" \
        -e "s|UID|$(id -u)|g" \
        -e "s|GID|$(id -g)|g" \
        "${pingu_cfg_template}" >pingu.yaml

    # running pingu
    sudo -E timeout "${timeout}s" "${pingu_bin}" pingu.yaml -vvv --purge fuzz

    # replay_step / gcov_step are accepted for dispatcher compatibility.
    # pingu gcov handles replay and coverage collection.
    sudo -E "${pingu_bin}" pingu.yaml -vvv gcov --purge

    sudo -E chmod -R 755 $work_dir
    sudo -E chown -R $(id -u):$(id -g) $work_dir
    cd ${HOME}/target/gcov/consumer/openssl
    mkdir -p ${work_dir}/cov_html
    gcovr -r . --html --html-details -o ${work_dir}/cov_html/index.html

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/openssl target/gcov/consumer/openssl
    pushd target/gcov/consumer/openssl >/dev/null

    export CFLAGS="-fprofile-arcs -ftest-coverage -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"

    ./config --with-rand-seed=devrandom no-shared no-threads no-tests no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function build_asan {
    target_ref="${1:-$OPENSSL_ECH_BASELINE}"

    if [ ! -d ".git-cache/openssl" ]; then
        git clone --no-single-branch https://github.com/openssl/openssl.git .git-cache/openssl
    fi

    mkdir -p repo
    rm -rf repo/openssl-raw
    cp -r .git-cache/openssl repo/openssl-raw

    pushd repo/openssl-raw >/dev/null
    git fetch origin "${OPENSSL_ECH_BRANCH}"
    git checkout "${target_ref}"
    popd >/dev/null

    mkdir -p target/asan
    rm -rf target/asan/*
    cp -r repo/openssl-raw target/asan/openssl
    pushd target/asan/openssl >/dev/null

    export CC=clang
    export CXX=clang++
    export CFLAGS="-O0 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O0 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    ./config --with-rand-seed=devrandom enable-asan no-shared no-threads no-tests no-asm no-cached-fetch no-async ${OPENSSL_REDUCED_FEATURE_FLAGS}
    bear -- make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    cert_dir=${HOME}/profuzzbench/cert
    mkdir -p "${cert_dir}"

    # ECH materials are needed when testing ECH-related handshake paths.
    # Reuse existing files if present; otherwise generate via ASAN OpenSSL.
    if ! compgen -G "${cert_dir}/*[Ee][Cc][Hh]*.pem" >/dev/null; then
        ech_openssl="${HOME}/target/asan/openssl/apps/openssl"
        if [ ! -x "${ech_openssl}" ]; then
            echo "[!] Missing OpenSSL binary for ECH generation: ${ech_openssl}"
            return 1
        fi
        if ! "${ech_openssl}" ech -help >/dev/null 2>&1; then
            echo "[!] OpenSSL binary does not support 'ech' subcommand: ${ech_openssl}"
            return 1
        fi
        "${ech_openssl}" ech \
            -public_name localhost \
            -out "${cert_dir}/echconfig.pem"
        chmod 644 "${cert_dir}/echconfig.pem"
        echo "[+] Generated ECH material: ${cert_dir}/echconfig.pem using ${ech_openssl}"
    else
        echo "[+] Found existing ECH material in ${cert_dir}, skip generation."
    fi

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}

function cleanup_artifacts {
    echo "No artifacts"
}
