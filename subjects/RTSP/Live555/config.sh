#!/usr/bin/env bash

function checkout {
    mkdir -p repo
    git clone https://github.com/rgaufman/live555.git repo/live555
    pushd repo/live555 >/dev/null
    git checkout "$@"
    git apply ${HOME}/profuzzbench/subjects/RTSP/Live555/ft-live555.patch
    
    popd >/dev/null
}

function replay {
    # 启动后台的 aflnet-replay
    ${HOME}/aflnet/aflnet-replay $1 RTSP 8554 1 &

    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 0 3s ./testOnDemandRTSPServer 8554

    wait

    # 再次 kill 进程一次，确保进程停止
    pkill testOnDemandR
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/live555 target/aflnet/live555
    pushd target/aflnet/live555 >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    export CFLAGS="-O3 -g -DFT_FUZZING -fsanitize=address"
    export CXXFLAGS="-O3 -g -DFT_FUZZING -fsanitize=address"
    export LDFLAGS="-fsanitize=address"

    sed -i "s@^C_COMPILER.*@C_COMPILER = $CC@g" config.linux
    sed -i "s@^CPLUSPLUS_COMPILER.*@CPLUSPLUS_COMPILER = $CXX@g" config.linux
    sed -i "s@^LINK =.*@LINK = $CXX -o@g" config.linux

    ./genMakefiles linux
    
    make ${MAKE_OPT}

    popd >/dev/null
}

function run_aflnet {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/RTSP/Live555/in-rtsp
    pushd ${HOME}/target/aflnet/live555/testProgs >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/aflnet/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/8554 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -W 50 -m none \
        ./testOnDemandRTSPServer 8554

    cd ${HOME}/target/gcov/consumer/live555/testProgs

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | awk 'NR % ${replay_step} == 0' | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r .. -s | grep \"[lb][a-z]*:\""
    gcovr -r .. -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r .. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_stateafl {
    mkdir -p target/stateafl
    rm -rf target/stateafl/*
    cp -r repo/live555 target/stateafl/live555
    pushd target/stateafl/live555 >/dev/null
   
    export CC=${HOME}/stateafl/afl-clang-fast
    export CXX=${HOME}/stateafl/afl-clang-fast++
    export CFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING"
    export CXXFLAGS="-g -O3 -fsanitize=address -DFT_FUZZING"
    export LDFLAGS="-fsanitize=address"

    sed -i "s@^C_COMPILER.*@C_COMPILER = $CC@g" config.linux
    sed -i "s@^CPLUSPLUS_COMPILER.*@CPLUSPLUS_COMPILER = $CXX@g" config.linux
    sed -i "s@^LINK =.*@LINK = $CXX -o@g" config.linux

    ./genMakefiles linux
    make -j

    popd >/dev/null
}

# TODO:
# stateafl 插桩之后 testOnDemandRTSPServer 会出现内存泄漏，因此这里暂时将 detect_leaks 设置为 0
function run_stateafl {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/RTSP/Live555/in-rtsp-replay
    pushd ${HOME}/target/stateafl/live555/testProgs >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/8554 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -m none -t 1000 \
        ./testOnDemandRTSPServer 8554
    
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r .. -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/live555/testProgs

    gcovr -r .. -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r .. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_sgfuzz {
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/live555 target/sgfuzz/live555

    pushd target/sgfuzz/live555 >/dev/null

    git reset --hard HEAD
    git apply ${HOME}/profuzzbench/subjects/RTSP/Live555/ft-sgfuzz-live555.patch

    export LLVM_COMPILER=clang
    export CC=wllvm
    export CXX=wllvm++
    export CFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    export CXXFLAGS="-O0 -g -fno-inline-functions -fno-inline -fno-discard-value-names -fno-vectorize -fno-slp-vectorize -DFT_FUZZING -DSGFUZZ -v -Wno-int-conversion"
    
    python3 $HOME/sgfuzz/sanitizer/State_machine_instrument.py .

    sed -i "s@^C_COMPILER.*@C_COMPILER = $CC@g" config.linux
    sed -i "s@^CPLUSPLUS_COMPILER.*@CPLUSPLUS_COMPILER = $CXX@g" config.linux
    sed -i "s@^LINK =.*@LINK = $CXX -o@g" config.linux

    ./genMakefiles linux
    make -j
    cd testProgs
    extract-bc testOnDemandRTSPServer

    export SGFUZZ_USE_HF_MAIN=1
    export SGFUZZ_PATCHING_TYPE_FILE=${HOME}/target/sgfuzz/live555/enum_types.txt
    opt -load-pass-plugin=${HOME}/sgfuzz-llvm-pass/sgfuzz-source-pass.so \
        -passes="sgfuzz-source" -debug-pass-manager testOnDemandRTSPServer.bc -o testOnDemandRTSPServer_opt.bc

    llvm-dis-17 testOnDemandRTSPServer_opt.bc -o testOnDemandRTSPServer_opt.ll
    sed -i 's/optnone //g' testOnDemandRTSPServer_opt.ll

    clang++ testOnDemandRTSPServer_opt.ll -o testOnDemandRTSPServer \
        -L. \
        -lsFuzzer \
        -lhfnetdriver \
        -lhfcommon \
        -lssl \
        -lcrypto \
        -lstdc++ \
        -fsanitize=address \
        -fsanitize=fuzzer \
        -DFT_FUZZING \
        -DFT_CONSUMER \
        -DSGFUZZ \
        ../liveMedia/libliveMedia.a \
        ../groupsock/libgroupsock.a \
        ../BasicUsageEnvironment/libBasicUsageEnvironment.a \
        ../UsageEnvironment/libUsageEnvironment.a

    popd >/dev/null
}

function run_sgfuzz {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/RTSP/Live555/in-rtsp
    pushd ${HOME}/target/sgfuzz/live555/testProgs >/dev/null

    mkdir -p $outdir/replayable-queue
    rm -rf $outdir/replayable-queue/*
    mkdir -p $outdir/crash
    rm -rf $outdir/crash/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"
    export HFND_TCP_PORT=8554
    export HFND_FORK_MODE=1

    SGFuzz_ARGS=(
        -max_len=100000
        -close_fd_mask=3
        -shrink=1
        -print_full_coverage=1
        -reduce_inputs=1
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

    LIVE555_ARGS=(
        8554
    )

    ./testOnDemandRTSPServer "${SGFuzz_ARGS[@]}" -- "${LIVE555_ARGS[@]}"

    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${outdir}/replayable-queue
    cov_cmd="gcovr -r .. -s ${MAKE_OPT} | grep \"[lb][a-z]*:\""
    list_cmd="ls -1 ${outdir}/replayable-queue/* | tr '\n' ' ' | sed 's/ $//'"
    cd ${HOME}/target/gcov/consumer/live555/testProgs

    function replay {
        ${HOME}/aflnet/afl-replay $1 RTSP 8554 1 &
        LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
            timeout -k 0 1s ./testOnDemandRTSPServer 8554

        wait
        pkill -f testOnDemandRTSPServer
    }

    gcovr -r .. -s -d >/dev/null 2>&1
    compute_coverage replay "$list_cmd" ${gcov_step} ${outdir}/coverage.csv "$cov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r .. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_ft_generator {
    mkdir -p target/ft/generator
    rm -rf target/ft/generator/*
    cp -r repo/live555 target/ft/generator/live555
    pushd target/ft/generator/live555 >/dev/null

    export FT_CALL_INJECTION=1
    export FT_HOOK_INS=call,branch,load,store,select,switch
    export CC=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast
    export CXX=${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-clang-fast++
    export CFLAGS="-O0 -g -DFT_FUZZING -DFT_GENERATOR"
    export CXXFLAGS="-O0 -g -DFT_FUZZING -DFT_GENERATOR"
    export GENERATOR_AGENT_SO_DIR="${HOME}/fuzztruction-net/target/release/"
    export LLVM_PASS_SO="${HOME}/fuzztruction-net/generator/pass/fuzztruction-source-llvm-pass.so"

    sed -i "s@^C_COMPILER.*@C_COMPILER = $CC@g" config.linux
    sed -i "s@^CPLUSPLUS_COMPILER.*@CPLUSPLUS_COMPILER = $CXX@g" config.linux
    sed -i "s@^LINK =.*@LINK = $CXX -o@g" config.linux

    ./genMakefiles linux
    make ${MAKE_OPT}

    popd >/dev/null
}

function build_ft_consumer {
    sudo cp ${HOME}/profuzzbench/scripts/ld.so.conf/ft-net.conf /etc/ld.so.conf.d/
    sudo ldconfig

    mkdir -p target/ft/consumer
    rm -rf target/ft/consumer/*
    cp -r repo/live555 target/ft/consumer/live555
    pushd target/ft/consumer/live555 >/dev/null

    export AFL_PATH=${HOME}/fuzztruction-net/consumer/aflpp-consumer
    export CC=${AFL_PATH}/afl-clang-fast
    export CXX=${AFL_PATH}/afl-clang-fast++
    export CFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export CXXFLAGS="-fsanitize=address -O3 -g -DFT_FUZZING -DFT_CONSUMER"
    export LDFLAGS="-fsanitize=address"

    sed -i "s@^C_COMPILER.*@C_COMPILER = $CC@g" config.linux
    sed -i "s@^CPLUSPLUS_COMPILER.*@CPLUSPLUS_COMPILER = $CXX@g" config.linux
    sed -i "s@^LINK =.*@LINK = $CXX -o@g" config.linux
    
    ./genMakefiles linux
    make ${MAKE_OPT}

    popd >/dev/null
}

function run_ft {
    replay_step=$1
    gcov_step=$2
    timeout=$3
    consumer="Live555"
    generator=${GENERATOR:-$consumer}
    work_dir=/tmp/fuzzing-output
    pushd ${HOME}/target/ft/ >/dev/null

    temp_file=$(mktemp)
    sed -e "s|WORK-DIRECTORY|${work_dir}|g" -e "s|UID|$(id -u)|g" -e "s|GID|$(id -g)|g" ${HOME}/profuzzbench/ft.yaml >"$temp_file"
    cat "$temp_file" >ft.yaml
    printf "\n" >>ft.yaml
    rm "$temp_file"
    cat ${HOME}/profuzzbench/subjects/RTSP/${generator}/ft-source.yaml >>ft.yaml
    cat ${HOME}/profuzzbench/subjects/RTSP/${consumer}/ft-sink.yaml >>ft.yaml
 
    # fuzzing
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction --purge ft.yaml fuzz -t ${timeout}s

    # collecting coverage results
    sudo ${HOME}/fuzztruction-net/target/release/fuzztruction ft.yaml gcov -t 3s
    sudo chmod -R 755 $work_dir
    sudo chown -R $(id -u):$(id -g) $work_dir
    cd ${HOME}/target/gcov/consumer/live555/testProgs
    mkdir -p ${work_dir}/cov_html
    gcovr -r .. --html --html-details -o ${work_dir}/cov_html/index.html
    
    popd >/dev/null
}

function build_pingu_generator {
    echo "Not implemented"

}

function build_pingu_consumer {
    echo "Not implemented"

}

function run_pingu {
    echo "Not implemented"

}

function build_gcov {
    mkdir -p target/gcov/consumer
    rm -rf target/gcov/consumer/*
    cp -r repo/live555 target/gcov/consumer/live555
    pushd target/gcov/consumer/live555 >/dev/null

    export CFLAGS="-fprofile-arcs -ftest-coverage"
    export CPPFLAGS="-fprofile-arcs -ftest-coverage"
    export CXXFLAGS="-fprofile-arcs -ftest-coverage"
    export LDFLAGS="-fprofile-arcs -ftest-coverage"

    ./genMakefiles linux
    make ${MAKE_OPT}

    popd >/dev/null
}

function install_dependencies {
    echo "No dependencies"
}
