#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://github.com/eclipse/mosquitto.git repo/mosquitto
    pushd repo/mosquitto >/dev/null
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/MQTT/Mosquitto/ft-mosquitto.patch
    popd >/dev/null
}


function replay {
    # 启动后台的aflnet-replay
    ${HOME}/stateafl/aflnet-replay $1 MQTT 7899 1 &

    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
    timeout -k 0 3s ./mosquitto -p 7899

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
    # echo "run_aflnet is called"
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/TLS/OpenSSL/in-tls
    pushd ${HOME}/target/aflnet/openssl >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    # echo "export is used"
    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/4433 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./apps/openssl s_server \
        -cert ${HOME}/profuzzbench/test.fullchain.pem \
        -key ${HOME}/profuzzbench/test.key.pem \
        -accept 4433 -4

    # echo "timeout is called"
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    cd ${HOME}/target/gcov/consumer/openssl
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv
    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {

    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/mosquitto target/stateafl/mosquitto
    pushd target/stateafl/mosquitto >/dev/null

   
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON ..
    make -j

    rm -rf fuzz test .git doc

    popd >/dev/null
}


# zkc stateafl
function run_stateafl {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/MQTT/Mosquitto/seeds/replayable/normal
    
    pushd ${HOME}/target/stateafl/mosquitto/build/src >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -m none -i $indir \
        -o $outdir \
        -N tcp://127.0.0.1/7899 \
        -q 3 -s 3 -R -E -K \
        -- ./mosquitto -p 7899 \
        
        

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r ../.. -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/mosquitto/build/src

    gcovr -r ../.. -s -d >/dev/null 2>&1

    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_sgfuzz {
    echo "Not implemented"
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
    export CFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-O3 -g -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -DFT_FUZZING -DFT_GENERATOR"
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
    grcov --branch --threads 2 -s . -t html . -o ${work_dir}/cov_html

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
    cp -r repo/mosquitto target/gcov/consumer/mosquitto
    pushd target/gcov/consumer/mosquitto >/dev/null

    
    export AFL_LLVM_LAF_SPLIT_SWITCHES=1
    export AFL_LLVM_LAF_TRANSFORM_COMPARES=1
    export AFL_LLVM_LAF_SPLIT_COMPARES=1

    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CPPFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"

   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON ..
    make -j

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function install_dependencies {
     sudo apt install -y xsltproc libcjson-dev docbook-xsl
}
