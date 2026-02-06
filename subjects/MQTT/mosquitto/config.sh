#!/usr/bin/env bash

function checkout {
    if [ ! -d ".git-cache/mosquitto" ]; then
        git clone --no-single-branch https://github.com/eclipse/mosquitto.git .git-cache/mosquitto
    fi

    mkdir -p repo
    cp -r .git-cache/mosquitto repo/mosquitto

    pushd repo/mosquitto >/dev/null

    git fetch --unshallow
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/MQTT/mosquitto/ft.patch
    
    popd >/dev/null
}

function replay {
    # 启动后台的 aflnet-replay
    /home/user/aflnet/aflnet-replay $1 MQTT 7899 1 &
    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so:libfaketime.so.1 FAKE_RANDOM=1 \
    timeout -k 1s 1s ./mosquitto -p 7899
    wait
}

function replay_poc {
    ${HOME}/aflnet/aflnet-replay $1 MQTT 7899 1 &
    err_output=$(timeout -k 0 -s SIGTERM 1s ./mosquitto -p 7899 > /dev/null)
    wait
    pkill mosquitto
    echo "$err_output"
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/mosquitto target/aflnet/mosquitto
    pushd target/aflnet/mosquitto >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export CFLAGS="-O3 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING -DASAN_REPORT_HOOK"
    export CXXFLAGS="-O3 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING -DASAN_REPORT_HOOK"
    export LDFLAGS="-fsanitize=address"
   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON -DWITH_TLS=OFF .. # -DWITH_TLS=OFF disable TLS to make sure util__random_bytes use random() or getrandom()
    make ${MAKE_OPT}
    
    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqtt
    pushd ${HOME}/target/aflnet/mosquitto/build/src >/dev/null
    
    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so:libfaketime.so.1
    export FAKETIME_ONLY_CMDS="mosquitto"
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    export AFL_NO_AFFINITY=1
    export ASAN_REPORT_PATH=${outdir}/replayable-crashes

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/7899 \
        -P MQTT -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./mosquitto -p 7899

    cd ${HOME}/target/gcov/consumer/mosquitto/build/src
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r ../.. -s | grep \"[lb][a-z]*:\""
    
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/mosquitto target/stateafl/mosquitto
    pushd target/stateafl/mosquitto >/dev/null
   
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-O3 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING"
    export CXXFLAGS="-O3 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING"
    export LDFLAGS="-fsanitize=address"
   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON -DWITH_TLS=OFF ..
    make ${MAKE_OPT}

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqtt-replay
    
    pushd ${HOME}/target/stateafl/mosquitto/build/src >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so:libfaketime.so.1
    export FAKETIME_ONLY_CMDS="mosquitto"
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1
    export ASAN_REPORT_PATH=${outdir}/replayable-crashes

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/7899 \
        -P MQTT -D 10000 -q 3 -s 3 -R -E -K -W 50 -m none \
        ./mosquitto -p 7899

    cd ${HOME}/target/gcov/consumer/mosquitto/build/src

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r ../.. -s | grep \"[lb][a-z]*:\""
    gcovr -r ../.. -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_sgfuzz {
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/mosquitto target/sgfuzz/mosquitto

    pushd target/sgfuzz/mosquitto >/dev/null
    
    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    
    python3 $HOME/sgfuzz/sanitizer/State_machine_instrument.py . 
    
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON -DWITH_TLS=OFF ..
    make ${MAKE_OPT}

    cd src
    extract-bc mosquitto

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE=${HOME}/target/sgfuzz/mosquitto/enum_types.txt
    opt -load-pass-plugin=${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so \
        -passes="sgfuzz-source" -debug-pass-manager mosquitto.bc -o mosquitto_opt.bc

    llvm-dis-17 mosquitto_opt.bc -o mosquitto_opt.ll
    sed -i 's/optnone //g' mosquitto_opt.ll

    clang mosquitto_opt.ll -o mosquitto \
        -lsFuzzer \
        -lhfnetdriver \
        -lhfcommon \
        -lz \
        -lm \
        -lstdc++ \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DSGFUZZ

    popd >/dev/null
}

function run_sgfuzz {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqtt
    pushd ${HOME}/target/sgfuzz/mosquitto/build/src >/dev/null

    mkdir -p $outdir/replayable-queue
    rm -rf $outdir/replayable-queue/*
    mkdir -p $outdir/crashes
    rm -rf $outdir/crashes/*

    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1
    export HFND_TCP_PORT=7899
    export HFND_FORK_MODE=1

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -shrink=1
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time=$timeout
        -fork=1
        -artifact_prefix="${outdir}/crashes/"
        "${outdir}/replayable-queue"
        "${indir}"
    )
    
    MOSQUITTO_ARGS=(
        -p 7899
    )

    ./mosquitto "${SGFuzz_ARGS[@]}" -- "${MOSQUITTO_ARGS[@]}"

    function replay {
        /home/user/aflnet/afl-replay $1 MQTT 7899 1 &
        LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
            timeout -k 0 1s ./mosquitto -p 7899

        wait
        pkill mosquitto
    }

    cd ${HOME}/target/gcov/consumer/mosquitto/build/src
    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${outdir}/replayable-queue
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"    
    gcov_cmd="gcovr -r ../.. -s | grep \"[lb][a-z]*:\""
    gcovr -r ../.. -s -d >/dev/null 2>&1
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$gcov_cmd"
    
    mkdir -p ${outdir}/cov_html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_asan {
    if [ ! -d ".git-cache/mosquitto" ]; then
        git clone --no-single-branch https://github.com/eclipse/mosquitto.git .git-cache/mosquitto
    fi

    mkdir -p repo
    cp -r .git-cache/mosquitto repo/mosquitto-raw

    pushd repo/mosquitto-raw >/dev/null

    git checkout "$1"
    
    popd >/dev/null

    mkdir -p target/asan
    rm -rf target/asan/*
    cp -r repo/mosquitto-raw target/asan/mosquitto
    pushd target/asan/mosquitto >/dev/null

    export CC=clang
    export CXX=clang++
    export CFLAGS="-O3 -fsanitize=address -fno-omit-frame-pointer"
    export CXXFLAGS="-O3 -fsanitize=address -fno-omit-frame-pointer"
    export LDFLAGS="-fsanitize=address"

    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON ..
    make ${MAKE_OPT}

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/mosquitto target/gcov/consumer/mosquitto
    pushd target/gcov/consumer/mosquitto >/dev/null

    export CFLAGS="-O0 -g -fprofile-arcs -ftest-coverage -DFT_FUZZING -DFT_CONSUMER"
    export CPPFLAGS="-O0 -g -fprofile-arcs -ftest-coverage -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O0 -g -fprofile-arcs -ftest-coverage -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-g -fprofile-arcs -ftest-coverage"

    mkdir build && cd build
    cmake -DWITH_STATIC_LIBRARIES=ON -DWITH_TLS=OFF ..
    make ${MAKE_OPT}

    popd >/dev/null
}

function build_ft_consumer {
    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/ft-net.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/mosquitto target/ft/consumer/mosquitto
    pushd target/ft/consumer/mosquitto >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-g -O3 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-g -O3 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"
   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON -DWITH_TLS=OFF ..
    make ${MAKE_OPT}
    
    popd >/dev/null
}

function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/mosquitto target/ft/generator/mosquitto
    pushd target/ft/generator/mosquitto >/dev/null

    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=call,branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-g -O0 -fno-omit-frame-pointer -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-g -O0 -fno-omit-frame-pointer -DFT_FUZZING -DFT_GENERATOR"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"
   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON -DWITH_TLS=OFF ..
    make ${MAKE_OPT}
    
    popd >/dev/null
}

function run_ft {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    consumer="mosquitto"
    generator=${GENERATOR:-$consumer}
    work_dir=/tmp/fuzzing-output
    pushd ${HOME}/target/ft/ >/dev/null

    # synthesize the ft configuration yaml
    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" -e "s|UID|$(id -u)|g" -e "s|GID|$(id -g)|g" ${HOME}/profuzzbench/ft.yaml >"$temp_file"
    cat "$temp_file" >ft.yaml
    printf "\n" >>ft.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/MQTT/${generator}/ft-source.yaml >>ft.yaml
    cat ${HOME}/profuzzbench/subjects/MQTT/${consumer}/ft-sink.yaml >>ft.yaml

    # running ft-net fuzzing
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction --purge ft.yaml fuzz -t ${timeout}s

    # collecting coverage results
    cd ${HOME}/target/gcov/consumer/mosquitto/build/src
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ${HOME}/target/ft/ft.yaml gcov -t 3s
    sudo chmod -R 755 $work_dir
    sudo chown -R $(id -u):$(id -g) $work_dir
    mkdir -p ${work_dir}/cov_html
    gcovr -r ../.. --html --html-details -o ${work_dir}/cov_html/index.html

    popd >/dev/null
}

function install_dependencies {
    sudo -E apt update
    sudo -E apt install -y xsltproc libcjson-dev docbook-xsl libssl-dev
}
