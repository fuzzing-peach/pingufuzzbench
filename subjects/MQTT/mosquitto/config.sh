#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://github.com/eclipse/mosquitto.git repo/mosquitto
    pushd repo/mosquitto >/dev/null
    git checkout "$@"
    git apply --check "${HOME}/profuzzbench/subjects/MQTT/mosquitto/ft.patch"
    popd >/dev/null
}

function replay {
    # 启动后台的 aflnet-replay
    /home/user/aflnet/aflnet-replay $1 MQTT 7899 1 &
    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
    timeout -k 1s 1s ./mosquitto -p 7899
    wait
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/mosquitto target/aflnet/mosquitto
    pushd target/aflnet/mosquitto >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export CFLAGS="-g -O0 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING"
    export CXXFLAGS="-g -O0 -fsanitize=address -fno-omit-frame-pointer -DFT_FUZZING"
    export LDFLAGS="-fsanitize=address"
   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON ..
    make -j
    
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
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/7899 \
        -P MQTT -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
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

    popd >/dev/null
}


function install_dependencies {
    sudo apt update
    sudo apt install -y xsltproc libcjson-dev docbook-xsl
}
