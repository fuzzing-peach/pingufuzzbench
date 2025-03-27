function checkout {
    mkdir -p repo
    git clone https://github.com/DCMTK/dcmtk.git repo/Dcmtk
    pushd repo/Dcmtk >/dev/null
    git checkout "$@"
    git apply "${HOME}/profuzzbench/subjects/DICOM/Dcmtk/ft-dcmtk.patch"
    
    popd >/dev/null
}

function replay {
    ${HOME}/aflnet/aflnet-replay $1 DICOM 5158 1 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 0 -s SIGTERM 3s ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp --single-process --config ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp.cfg
    wait
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/Dcmtk target/stateafl/dcmtk
    pushd target/stateafl/dcmtk >/dev/null

    git apply ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/buffer.patch

    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}

    cd bin
    mkdir ACME_STORE
    cp /home/user/profuzzbench/subjects/DICOM/Dcmtk/dcmqrscp.cfg ./
    
    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_stateafl {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/Dcmtk/in-dicom-replay
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
        -c ${WORKDIR}/clean ./dcmqrscp --single-process --config ./dcmqrscp.cfg

    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv

    echo "Current directory in run_stateafl: $(pwd)"

    mkdir -p ${outdir}/cov_html
    # gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html
    gcovr -r ../.. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/Dcmtk target/aflnet/dcmtk
    pushd target/aflnet/dcmtk >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export CFLAGS="-O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}

    cd bin
    # Create directory for DICOM database
    if [ ! -d "ACME_STORE" ]; then
        mkdir ACME_STORE
    fi

    cp ${HOME}/profuzzbench/subjects/DICOM/Dcmtk/dcmqrscp.cfg ./

    popd >/dev/null
}

function run_aflnet {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/Dcmtk/in-dicom
    pushd ${HOME}/target/aflnet/dcmtk/build/bin >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    export DCMDICTPATH=${HOME}/target/aflnet/dcmtk/dcmdata/data/dicom.dic

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5158 \
        -P DICOM -D 10000 -q 3 -s 3 -E -K -R -W 50  -m none \
        ${HOME}/target/aflnet/dcmtk/bin/dcmqrscp --single-process --config ./dcmqrscp.cfg

    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    eval $list_cmd
    cd ${HOME}/target/gcov/consumer/dcmtk

    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv
    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/Dcmtk target/gcov/consumer/dcmtk
    pushd target/gcov/consumer/dcmtk >/dev/null

    export CFLAGS="-O3 -DFT_FUZZING -DFT_CONSUMER -g -fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-O3 -DFT_FUZZING -DFT_CONSUMER -g -fprofile-arcs -ftest-coverage"
    export LDFLAGS="-g -fprofile-arcs -ftest-coverage"
   
    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}

    cd bin
    if [ ! -d "ACME_STORE" ]; then
        mkdir ACME_STORE
    fi
    cp /home/user/profuzzbench/subjects/DICOM/Dcmtk/dcmqrscp.cfg ./

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}
