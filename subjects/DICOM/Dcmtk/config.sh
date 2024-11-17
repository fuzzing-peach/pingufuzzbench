#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://git.dcmtk.org/dcmtk.git repo/dcmtk
    pushd repo/dcmtk >/dev/null
    git checkout "$@"
    
    popd >/dev/null
}

function replay {
    # the process launching order is confusing.
    ${HOME}/stateafl/aflnet-replay $1 DICOM 5158 1 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 0 -s SIGTERM 3s ./dcmqrscp --single-process --config ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp.cfg
    wait
}


function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/dcmtk target/stateafl/dcmtk
    pushd target/stateafl/dcmtk >/dev/null
    

    git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/fuzzing.patch
    git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/buffer.patch

    export ASAN_OPTIONS=detect_leaks=0
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"
    

    mkdir build && cd build
    cmake ..
    
    export AFL_USE_ASAN=1 
    make dcmqrscp
   

    cd bin
    mkdir ACME_STORE
    cp ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/dcmqrscp.cfg ./

    rm -rf fuzz test .git doc

    popd >/dev/null
}


# zkc stateafl
function run_stateafl {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/Dcmtk/in-dicom-replay
    pushd ${HOME}/target/stateafl/dcmtk/build/bin >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export DCMDICTPATH=${HOME}/profuzzbench/subjects/DICOM/Dcmtk/dicom.dic
    
    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export AFL_NO_AFFINITY=1

    

    
    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5158 \
        -P DICOM -D 10000 -E -K -m none -t 1000 \
        ./dcmqrscp --config ${HOME}/target/stateafl/dcmtk/build/bin/dcmqrscp.cfg --single-process



    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c  /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l   /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c  /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l   /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r ../.. -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/dcmtk/build/bin

    gcovr -r ../.. -s -d >/dev/null 2>&1
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$gcov_cmd"

    mkdir -p ${outdir}/cov_html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}


function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/dcmtk target/gcov/consumer/dcmtk
    pushd target/gcov/consumer/dcmtk >/dev/null


    git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/normal.patch
    mkdir build && cd build

    cmake -G"Unix Makefiles" .. -DCMAKE_C_FLAGS="-g -fprofile-arcs -ftest-coverage" -DCMAKE_CXX_FLAGS="-g -fprofile-arcs -ftest-coverage"
    make dcmqrscp

    cd bin
    mkdir ACME_STORE
    cp /home/user/profuzzbench/subjects/DICOM/Dcmtk/dcmqrscp.cfg ./

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}
