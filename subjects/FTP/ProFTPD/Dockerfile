ARG proxy=http://172.17.0.1:7890
ARG MAKE_OPT
ARG LIBAFLNET_VERSION=1.1.0

####################################
# Build ProFTPD Image
####################################
FROM libaflnet-afl:1.0.0 AS proftpd

ENV http_proxy=$proxy
ENV https_proxy=$proxy

USER ubuntu
WORKDIR /home/ubuntu

# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV STATEAFL="/home/ubuntu/stateafl"
ENV LIBAFLNET="/home/ubuntu/libaflnet"
ENV PATH="${PATH}:${AFLNET}:/home/ubuntu/.local/bin:${WORKDIR}"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1

RUN mkdir $WORKDIR

# Set up environment variables for ASAN
env ASAN_OPTIONS='abort_on_error=1:symbolize=0:detect_leaks=0:detect_stack_use_after_return=1:detect_container_overflow=0:poison_array_cookie=0:malloc_fill_byte=0:max_malloc_fill_size=16777216'

RUN git config --global http.proxy $proxy && \
    git config --global https.proxy $proxy

# Download and compile ProFTPD for fuzzing
RUN cd ${WORKDIR} && \
    git clone --depth=1 https://github.com/proftpd/proftpd.git && \
    cp -r proftpd proftpd-gcov && \
    cp -r proftpd proftpd-stateafl && \
    cd proftpd && \
    git fetch --unshallow && \
    git checkout 4017eff8 && \
    CC="afl-clang-fast" CXX="afl-clang-fast++" ./configure --enable-devel=nodaemon:nofork && \
    AFL_USE_ASAN=1 make $MAKE_OPT

# Download and compile ProFTPD for coverage analysis
RUN cd ${WORKDIR}/proftpd-gcov && \
    git fetch --unshallow && \
    git checkout 4017eff8 && \
    CFLAGS="-fprofile-arcs -ftest-coverage" CPPFLAGS="-fprofile-arcs -ftest-coverage" CXXFLAGS="-fprofile-arcs -ftest-coverage" LDFLAGS="-fprofile-arcs -ftest-coverage" ./configure --enable-devel=nodaemon:nofork && \
    make $MAKE_OPT

COPY --chown=ubuntu:ubuntu malloc.patch ${WORKDIR}/malloc.patch

RUN cd ${WORKDIR}/proftpd-stateafl && \
    git checkout 4017eff8 && \
    patch -p1 < ${WORKDIR}/malloc.patch && \
    CC=${STATEAFL}/afl-clang-fast CXX=${STATEAFL}/afl-clang-fast++ ./configure --enable-devel=nodaemon:nofork && \
    make $MAKE_OPT

# For deterministic timestamps
RUN cd ${WORKDIR} && \
    git clone https://github.com/stateafl/libfaketime-asan-fixed libfaketime-asan-fixed && \
    cd libfaketime-asan-fixed && \
    git checkout 7e46ea4 && \
    cd src && \
    make

####################################
# Build Testing Image with fuzzers:
# - aflnet
# - aflnwe
# - libaflnet
####################################
FROM libaflnet-rust:1.0.0

ARG GITHUB_TOKEN

ENV http_proxy=$proxy
ENV https_proxy=$proxy

USER ubuntu
WORKDIR /home/ubuntu

# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV AFLNWE="/home/ubuntu/aflnwe"
ENV LIBAFLNET="/home/ubuntu/libaflnet"
ENV PATH="${PATH}:${AFLNET}:/home/ubuntu/.local/bin:${WORKDIR}"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1 \
    AFL_NO_AFFINITY=1

# Clone and compile libaflnet
RUN git clone https://Kherrisan:$GITHUB_TOKEN@github.com/Kherrisan/libaflnet.git
    
WORKDIR /home/ubuntu/libaflnet

RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/src/target \
    . $HOME/.cargo/env && \
    RUSTFLAGS="-A warnings" cargo build -Z unstable-options --release --out-dir /home/ubuntu/libaflnet

RUN mkdir /home/ubuntu/ftpshare && \
    chown -R ubuntu:ubuntu /home/ubuntu/ftpshare

# Copy fuzzing target from prebuilt image: proftpd:1.0.0
COPY --chown=ubuntu:ubuntu --from=proftpd ${WORKDIR}/proftpd ${WORKDIR}/proftpd
COPY --chown=ubuntu:ubuntu --from=proftpd ${WORKDIR}/proftpd-gcov ${WORKDIR}/proftpd-gcov
COPY --chown=ubuntu:ubuntu basic.conf ${WORKDIR}/
COPY --chown=ubuntu:ubuntu in-ftp ${WORKDIR}/in-ftp
COPY --chown=ubuntu:ubuntu ftp.dict ${WORKDIR}/ftp.dict
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
COPY --chown=ubuntu:ubuntu clean.sh ${WORKDIR}/clean
COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script
COPY --chown=ubuntu:ubuntu in-ftp-replay ${WORKDIR}/in-ftp-replay
COPY --chown=ubuntu:ubuntu run-stateafl.sh ${WORKDIR}/run-stateafl
COPY --chown=ubuntu:ubuntu blacklist.sh ${WORKDIR}/blacklist.sh

# The server runs in "/home/ubuntu" if login succeeds,
# otherwise, the CWD is $TARGETDIR. Create a link to share the same files for MVP tree.
RUN touch /home/ubuntu/.tree.mvp && \
    chmod ugo+rw /home/ubuntu/.tree.mvp && \
    ln /home/ubuntu/.tree.mvp ${WORKDIR}/proftpd-stateafl/.tree.mvp

RUN touch /home/ubuntu/.tree.count.mvp && \
    chmod ugo+rw /home/ubuntu/.tree.count.mvp && \
    ln /home/ubuntu/.tree.count.mvp ${WORKDIR}/proftpd-stateafl/.tree.count.mvp

# Switch default user to root
USER root
WORKDIR /home/ubuntu

ENV LD_PRELOAD=$WORKDIR/libfaketime-asan-fixed/src/libfaketime.so.1
ENV FAKETIME="2000-01-01 11:12:13"
ENV FAKETIME_ONLY_CMDS="proftpd"