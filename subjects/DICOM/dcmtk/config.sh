function checkout {
    mkdir -p repo
    git clone --no-single-branch https://github.com/dcmtk/dcmtk.git repo/dcmtk
    pushd repo/dcmtk >/dev/null
    git fetch --unshallow
    git checkout "$@"
    git apply "${HOME}/profuzzbench/subjects/DICOM/dcmtk/ft-dcmtk.patch"
    
    popd >/dev/null
}

function replay {
    ${HOME}/aflnet/aflnet-replay $1 DICOM 5158 1 &
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 0 -s SIGTERM 3s ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp --single-process --config ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp.cfg
    wait

    pkill dcmqrscp
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/dcmtk target/aflnet/dcmtk
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

    cp ${HOME}/profuzzbench/subjects/DICOM/dcmtk/dcmqrscp.cfg ./

    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/dcmtk/in-dicom
    pushd ${HOME}/target/aflnet/dcmtk/build/bin >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    export DCMDICTPATH=${HOME}/profuzzbench/subjects/DICOM/dcmtk/dicom.dic
    export WORKDIR=${HOME}/target/aflnet/dcmtk/build/bin

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5158 \
        -P DICOM -D 10000 -q 3 -s 3 -E -K -R -W 50  -m none \
        -c ${HOME}/profuzzbench/subjects/DICOM/dcmtk/clean.sh \
        ./dcmqrscp --single-process --config ./dcmqrscp.cfg

    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    
    cd ${HOME}/target/gcov/consumer/dcmtk
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    clean_cmd="rm -f ${HOME}/target/gcov/consumer/dcmtk/build/bin/ACME_STORE/*"

    compute_coverage replay "$list_cmd" "${gcov_step}" "${outdir}/coverage.csv" "" "$clean_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/dcmtk target/stateafl/dcmtk
    pushd target/stateafl/dcmtk >/dev/null

    git apply ${HOME}/profuzzbench/subjects/DICOM/dcmtk/buffer.patch

    export ASAN_OPTIONS=detect_leaks=0
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-O3 -g -fsanitize=address -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}

    cd bin
    mkdir ACME_STORE
    cp /home/user/profuzzbench/subjects/DICOM/dcmtk/dcmqrscp.cfg ./
    
    rm -rf fuzz test .git doc

    popd >/dev/null
}

function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/dcmtk/in-dicom-replay
    pushd ${HOME}/target/stateafl/dcmtk/build/bin >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export DCMDICTPATH=${HOME}/profuzzbench/subjects/DICOM/dcmtk/dicom.dic
    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/5158 \
        -P DICOM -D 10000 -E -K -m none -t 1000 \
        -c ${HOME}/profuzzbench/subjects/DICOM/dcmtk/clean.sh ./dcmqrscp --single-process --config ./dcmqrscp.cfg

    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir

    cd ${HOME}/target/gcov/consumer/dcmtk
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    clean_cmd="rm -f ${HOME}/target/gcov/consumer/dcmtk/build/bin/ACME_STORE/*"
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "" "$clean_cmd"

    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/dcmtk target/gcov/consumer/dcmtk
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
    cp /home/user/profuzzbench/subjects/DICOM/dcmtk/dcmqrscp.cfg ./

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}
