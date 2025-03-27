#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://github.com/eclipse/mosquitto.git repo/mosquitto
    pushd repo/mosquitto >/dev/null
    git checkout "$@"
    git checkout v2.0.18
    git apply --check "${HOME}/profuzzbench/subjects/MQTT/mosquitto/fuzzing copy.patch"
    popd >/dev/null 
    git clone https://github.com/aflnet/aflnet.git aflnetmqtt
    cd aflnetmqtt 
    git checkout  6d86ca0cf6852cfa7a776a77fb7886d8bee46c14
    git apply /tmp/patches/aflnet.patch 
    make clean all ${MAKE_OPT} 
    cd llvm_mode 
    make ${MAKE_OPT} 
}

function replay {
    # 启动后台的 aflnet-replay
    /home/user/aflnetmqtt/aflnet-replay $1 MQTT 7899 1 &
    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
    timeout -k 1s 3s ./mosquitto -p 7899
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
   
    mkdir build
    cd build
    cmake -DWITH_STATIC_LIBRARIES=ON ..
    make -j
    
    popd >/dev/null
}

function run_aflnet {
    timeout=$1
    outdir=/tmp/fuzzing-output
 #    indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqttqq
   indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqtt
 #  indir=${HOME}/profuzzbench/subjects/MQTT/mosquitto/in-mqtt-replay
    pushd ${HOME}/target/aflnet/mosquitto/build/src >/dev/null
    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    echo "a"
    
    echo "b"
    

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnetmqtt/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/7899 \
        -P MQTT -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./mosquitto -p 7899
 



    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r ../.. -s | grep \"[lb][a-z]*:\""
   
    cd ${HOME}/target/gcov/consumer/mosquitto/build/src
    gcovr -r ../.. -s -d >/dev/null 2>&1
    

    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$gcov_cmd"
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
