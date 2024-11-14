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
    /home/user/aflnet/aflnet-replay $1 RTSP 8554 1 &

    # 预加载gcov和伪随机库，并限制服务器运行3秒
    LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
    timeout -k 0 3s ./testOnDemandRTSPServer 8554

    wait
}

function build_aflnet {
    mkdir -p target/aflnet
    rm -rf target/aflnet/*
    cp -r repo/live555 target/aflnet/live555
    pushd target/aflnet/live555 >/dev/null

    export CC=${HOME}/aflnet/afl-clang-fast
    export CXX=${HOME}/aflnet/afl-clang-fast++
    # --with-rand-seed=none only will raise: entropy source strength too weak
    # mentioned by: https://github.com/openssl/openssl/issues/20841
    # see https://github.com/openssl/openssl/blob/master/INSTALL.md#seeding-the-random-generator for selectable options for --with-rand-seed=X
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
    timeout=$1
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

    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r .. -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/live555/testProgs

    gcovr -r .. -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$gcov_cmd"
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

function run_stateafl {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/RTSP/Live555/in-rtsp-replay
    pushd ${HOME}/target/stateafl/live555/testProgs >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=0:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    timeout -k 0 --preserve-status $timeout \
        ${HOME}/stateafl/afl-fuzz -d -i $indir \
        -o $outdir -N tcp://127.0.0.1/8554 \
        -P TLS -D 10000 -q 3 -s 3 -E -K -R -m none -t 1000 \
        ./testOnDemandRTSPServer 8554
    
    list_cmd="ls -1 ${outdir}/replayable-queue/id* | tr '\n' ' ' | sed 's/ $//'"
    gcov_cmd="gcovr -r .. -s | grep \"[lb][a-z]*:\""
    cd ${HOME}/target/gcov/consumer/live555/testProgs

    gcovr -r .. -s -d >/dev/null 2>&1
    
    compute_coverage replay "$list_cmd" 1 ${outdir}/coverage.csv "$gcov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r .. --html --html-details -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_sgfuzz {
    mkdir -p target/sgfuzz
    rm -rf target/sgfuzz/*
    cp -r repo/live555 target/sgfuzz/live555
    pushd target/sgfuzz/live555 >/dev/null

    export CC=clang
    export CXX=clang++
    export CFLAGS="-g -O3 -fsanitize=address -fsanitize=fuzzer-no-link -DSGFUZZ -v -Wno-int-conversion"
    export CXXFLAGS="-g -O3 -fsanitize=address -fsanitize=fuzzer-no-link -DSGFUZZ -v -Wno-int-conversion"
    export LDFLAGS="-fsanitize=address -fsanitize=fuzzer-no-link"

    python3 $HOME/sgfuzz/sanitizer/State_machine_instrument.py . #  -b <(echo "EC_Normal\nOFFilename\nnptr")

    sed -i "s@^C_COMPILER.*@C_COMPILER = $CC@g" config.linux
    sed -i "s@^CPLUSPLUS_COMPILER.*@CPLUSPLUS_COMPILER = $CXX@g" config.linux
    sed -i "s@^LINK =.*@LINK = $CXX -o@g" config.linux

    set +e
    ./genMakefiles linux
    make -j
    set -e

    cd testProgs
    clang++ -otestOnDemandRTSPServer -L. -fsanitize=address -DFT_FUZZING -DSGFUZZ -DFT_CONSUMER testOnDemandRTSPServer.o announceURL.o ../liveMedia/libliveMedia.a ../groupsock/libgroupsock.a ../BasicUsageEnvironment/libBasicUsageEnvironment.a ../UsageEnvironment/libUsageEnvironment.a -lssl -lcrypto -lsFuzzer -lhfnetdriver -lhfcommon -lstdc++ -fsanitize=fuzzer -fsanitize=address -DSGFUZZ

    echo "done!"
    popd >/dev/null
}

function run_sgfuzz {
    timeout=$1
    outdir=/tmp/fuzzing-output
    indir=${HOME}/profuzzbench/subjects/RTSP/Live555/in-rtsp
    pushd ${HOME}/target/sgfuzz/live555/testProgs >/dev/null

    mkdir -p $outdir
    rm -rf $outdir/*

    export HFND_TCP_PORT=8554
    export AFL_SKIP_CPUFREQ=1
    export AFL_PRELOAD=libfake_random.so
    export FAKE_RANDOM=1 # fake_random is not working with -DFT_FUZZING enabled
    export ASAN_OPTIONS="abort_on_error=1:symbolize=1:detect_leaks=0:handle_abort=2:handle_segv=2:handle_sigbus=2:handle_sigill=2:detect_stack_use_after_return=0:detect_odr_violation=0"

    SGFuzz_ARGS=(
        -close_fd_mask=3
        -shrink=1
        -print_full_coverage=1
        -check_input_sha1=1
        -reduce_inputs=1
        -reload=30
        -print_final_stats=1
        -detect_leaks=0
        -max_total_time=$timeout
        "${outdir}"
        "${indir}"
    )

    LIVE555_ARGS=(
        8554
    )

    ./testOnDemandRTSPServer "${SGFuzz_ARGS[@]}" -- "${LIVE555_ARGS[@]}"

    python3 ${HOME}/profuzzbench/scripts/sort_libfuzzer_findings.py ${outdir}
    cov_cmd="gcovr -r .. -s ${MAKE_OPT} | grep \"[lb][a-z]*:\""
    list_cmd="ls -1 ${outdir}/* | tr '\n' ' ' | sed 's/ $//'"
    cd ${HOME}/target/gcov/consumer/live555/testProgs

    function replay {
        /home/user/aflnet/afl-replay $1 RTSP 8554 1 &
        LD_PRELOAD=libgcov_preload.so:libfake_random.so FAKE_RANDOM=1 \
        timeout -k 0 3s ./testOnDemandRTSPServer 8554

        wait
    }

    gcovr -r .. -s -d ${MAKE_OPT} >/dev/null 2>&1
    compute_coverage replay "$list_cmd" 10 ${outdir}/coverage.csv "$cov_cmd"
    mkdir -p ${outdir}/cov_html
    gcovr -r .. --html --html-details ${MAKE_OPT} -o ${outdir}/cov_html/index.html

    popd >/dev/null
}

function build_ft_generator {
    echo "Not implemented"

}

function build_ft_consumer {
    echo "Not implemented"

}

function run_ft {
    echo "Not implemented"

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
