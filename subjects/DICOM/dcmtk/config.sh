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
        timeout -k 0 -s SIGTERM 1s ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp --single-process --config ${HOME}/target/gcov/consumer/dcmtk/build/bin/dcmqrscp.cfg
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
    sed -i 's/aflnet/stateafl/g' dcmqrscp.cfg
    
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

function build_sgfuzz {
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/dcmtk target/sgfuzz/dcmtk

    pushd target/sgfuzz/dcmtk >/dev/null

    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"

    export FT_BLOCK_PATH_POSTFIXES="libsrc/ofchrenc.cc"
    python3 $HOME/sgfuzz/sanitizer/State_machine_instrument.py . -b $HOME/profuzzbench/subjects/DICOM/dcmtk/blocked_variable
    
    mkdir build && cd build
    cmake ..

    make dcmqrscp ${MAKE_OPT}
    cd bin
    extract-bc dcmqrscp

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE=${HOME}/target/sgfuzz/dcmtk/enum_types.txt
    export SGFUZZ_BLOCKING_TYPE_FILE=${HOME}/profuzzbench/subjects/DICOM/dcmtk/blocking-types.txt
    opt -load-pass-plugin=${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so \
        -passes="sgfuzz-source" -debug-pass-manager dcmqrscp.bc -o dcmqrscp_opt.bc

    clang dcmqrscp_opt.bc -o dcmqrscp \
        -lsFuzzer \
        -lhfnetdriver \
        -lhfcommon \
        -lz \
        -lm \
        -lstdc++ \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DFT_CONSUMER \
        -DSGFUZZ \
        ../lib/libdcmqrdb.a \
        ../lib/libdcmnet.a \
        ../lib/libdcmdata.a \
        ../lib/liboflog.a \
        ../lib/libofstd.a \
        ../lib/liboficonv.a 

    if [ ! -d "ACME_STORE" ]; then
        mkdir ACME_STORE
    fi
    cp /home/user/profuzzbench/subjects/DICOM/dcmtk/dcmqrscp.cfg ./
    sed -i 's/aflnet/sgfuzz/g' dcmqrscp.cfg

    popd >/dev/null
}

function run_sgfuzz {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/DICOM/dcmtk/in-dicom
    pushd ${HOME}/target/sgfuzz/dcmtk/build/bin >/dev/null

    mkdir -p $outdir/replayable-queue
    rm -rf $outdir/replayable-queue/*
    mkdir -p $outdir/crash
    rm -rf $outdir/crash/*

    export DCMDICTPATH=${HOME}/profuzzbench/subjects/DICOM/dcmtk/dicom.dic
    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=1:detect_odr_violation=0:detect_container_overflow=0:poison_array_cookie=0"
    export HFND_TCP_PORT=5158
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
        -artifact_prefix="${outdir}/crash/"
        -ignore_crashes=1
        "${outdir}/replayable-queue"
        "${indir}"
    )

    DCMTK_ARGS=(
        --single-process
        --config ./dcmqrscp.cfg
        -d
    )

    ./dcmqrscp "${SGFuzz_ARGS[@]}" -- "${DCMTK_ARGS[@]}"

    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.c /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir
    cp /home/user/repo/dcmtk/dcmdata/libsrc/vrscanl.l /home/user/target/gcov/consumer/dcmtk/build/dcmdata/libsrc/CMakeFiles/dcmdata.dir

    function replay {
        /home/user/aflnet/afl-replay $1 DICOM 5158 1 &
        LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
            timeout -k 0 1s ./build/bin/dcmqrscp --single-process --config ./build/bin/dcmqrscp.cfg

        wait
        pkill dcmqrscp
    }

    cd ${HOME}/target/gcov/consumer/dcmtk/
    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${outdir}/replayable-queue
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"    
    clean_cmd="rm -f ${HOME}/target/gcov/consumer/dcmtk/build/bin/ACME_STORE/*"
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "" "$clean_cmd"

    mkdir -p ${outdir}/cov_html
    gcovr -r . --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_ft_consumer {
    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/dcmtk target/ft/consumer/dcmtk
    pushd target/ft/consumer/dcmtk >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}
    
    popd >/dev/null
}

function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/dcmtk target/ft/generator/dcmtk
    pushd target/ft/generator/dcmtk >/dev/null
    
    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=call,branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O3 -g -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -DFT_GENERATOR"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"

    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}
    
    popd >/dev/null
}

function run_ft {
    timeout=$1
    replay_step=$2
    gcov_step=$3
    consumer="dcmtk"
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
    cat ${HOME}/profuzzbench/subjects/DICOM/${generator}/ft-source.yaml >>ft.yaml
    cat ${HOME}/profuzzbench/subjects/DICOM/${consumer}/ft-sink.yaml >>ft.yaml

    # running ft-net
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction --purge ft.yaml fuzz -t ${timeout}s
    
    
    
    
}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/dcmtk target/gcov/consumer/dcmtk
    pushd target/gcov/consumer/dcmtk >/dev/null

    export CFLAGS="-O3 -g -fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-O3 -g -fprofile-arcs -ftest-coverage"
    export LDFLAGS="-g -fprofile-arcs -ftest-coverage"
   
    mkdir build && cd build
    cmake ..
    make dcmqrscp ${MAKE_OPT}

    cd bin
    if [ ! -d "ACME_STORE" ]; then
        mkdir ACME_STORE
    fi
    cp /home/user/profuzzbench/subjects/DICOM/dcmtk/dcmqrscp.cfg ./
    sed -i 's/aflnet/sgfuzz/g' dcmqrscp.cfg

    rm -rf fuzz test .git doc

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}
