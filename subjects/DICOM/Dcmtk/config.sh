#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://git.dcmtk.org/dcmtk.git repo/dcmtk
    pushd repo/dcmtk >/dev/null
    git checkout "$@"
    # git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/ft-dcmtk.patch !!!
    # git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/normal.patch !!!
    popd >/dev/null
}

function replay {
    # the process launching order is confusing.
    # ${HOME}/aflnet/aflnet-replay $1 TLS 4433 100 &
    ${HOME}/stateafl/aflnet-replay $1 DICOM 5158 1 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 0 -s SIGTERM 3s ./dcmqrscp --single process 
    wait
}


function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/dcmtk target/stateafl/dcmtk
    pushd target/stateafl/dcmtk >/dev/null
    # !!!
    git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/fuzzing.patch

    export ASAN_OPTIONS=detect_leaks=0
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"
    

    mkdir build && cd build
    cmake ..
    # cmake ../src
    # cmake .
    make -j2

    cd bin
    mkdir ACME_STORE
    cp /home/user/profuzzbench/subjects/DICOM/Dcmtk/dcmqrscp.cfg ./
    
    rm -rf fuzz test .git doc

    popd >/dev/null
}


# zkc stateafl
function run_stateafl {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/Dcmtk/in-dicom-replay
    # pushd ${HOME}/target/stateafl/dcmtk >/dev/null
    pushd ${HOME}/target/stateafl/dcmtk/build/bin >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5158 \
        -P DICOM -D 10000 -E -K -m none -t 1000 \
        -c ${WORKDIR}/clean ./dcmqrscp --single-process

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    # cd ${HOME}/target/gcov/consumer/dcmtk
    cd ${HOME}/target/gcov/consumer/dcmtk/build/bin
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv

    echo "Current directory in run_stateafl: $(pwd)"

    mkdir -p ${outdir}/cov_html
    # gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}


function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/dcmtk target/gcov/consumer/dcmtk
    pushd target/gcov/consumer/dcmtk >/dev/null


    # !!!
    git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/normal.patch
    mkdir build && cd build
    
    # cmake -G"Unix Makefiles" . -DCMAKE_C_FLAGS="-g -fprofile-arcs -ftest-coverage" -DCMAKE_CXX_FLAGS="-g -fprofile-arcs -ftest-coverage"
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