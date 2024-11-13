#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://github.com/eclipse/mosquitto.git repo/mosquitto
    pushd repo/dcmtk >/dev/null
    git checkout "$@"
   # git apply "${HOME}/profuzzbench/subjects/MQTT/mosquitto/fuzzing.patch"
    popd >/dev/null
}

function replay {
    # 启动后台的 aflnet-replay
    /home/user/aflnet/aflnet-replay $1 MQTT  1883 &
    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
    timeout -k 0 3s ./src/mosquitto 
    wait
}


function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/mosquitto target/aflnet/mosquitto
    pushd target/aflnet/mosquitto >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export CFLAGS="-g -O0 -fsanitize=address -fno-omit-frame-pointer"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -fsanitize=address"
    export LDFLAGS="-fsanitize=address"
    export  CC=afl-gcc 
    ./make clean all WITH_TLS=no WITH_TLS_PSK:=no WITH_STATIC_LIBRARIES=yes WITH_DOCS=no WITH_CJSON=no WITH_EPOLL:=no

    popd >/dev/null
}

function run_aflnet {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqtt
    pushd ${HOME}/target/aflnet/mosquitto/testProgs >/dev/null
    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/1883 \
        -P MQTT -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./src/mosquitto 

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r .. -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/mosquitto/testProgs

    gcovr -r .. -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r .. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/mosquitto target/gcov/consumer/mosquitto
    pushd target/gcov/consumer/live555 >/dev/null
    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CPPFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"

    
    make clean all WITH_TLS=no WITH_TLS_PSK:=no WITH_STATIC_LIBRARIES=yes WITH_DOCS=no WITH_CJSON=no WITH_EPOLL:=no

    popd >/dev/null
}

function install_dependencies {
    sudo apt install -y xsltproc libcjson-dev docbook-xsl
}
