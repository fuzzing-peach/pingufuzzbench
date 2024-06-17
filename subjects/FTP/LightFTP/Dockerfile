ARG proxy=http://172.17.0.1:7890
ARG MAKE_OPT
ARG LIBAFLNET_VERSION=1.1.0

####################################
# Build LightFTP Image
####################################
FROM libaflnet-afl:1.0.0 AS lightftp

ENV http_proxy=$proxy
ENV https_proxy=$proxy

USER ubuntu
WORKDIR /home/ubuntu

# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV LIBAFLNET="/home/ubuntu/libaflnet"
ENV PATH="${PATH}:${AFLNET}:/home/ubuntu/.local/bin:${WORKDIR}"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1 \
    AFL_NO_AFFINITY=1

RUN mkdir $WORKDIR

COPY --chown=ubuntu:ubuntu fuzzing.patch ${WORKDIR}/fuzzing.patch
COPY --chown=ubuntu:ubuntu gcov.patch ${WORKDIR}/gcov.patch

# Set up environment variables for ASAN
env ASAN_OPTIONS='abort_on_error=1:symbolize=0:detect_leaks=0:detect_stack_use_after_return=1:detect_container_overflow=0:poison_array_cookie=0:malloc_fill_byte=0:max_malloc_fill_size=16777216'

RUN git config --global http.proxy $proxy && \
    git config --global https.proxy $proxy

# Download and compile LightFTP for fuzzing
RUN cd $WORKDIR && \
    git clone https://github.com/hfiref0x/LightFTP.git && \
    cp -r LightFTP LightFTP-gcov && \
    cp -r LightFTP LightFTP-stateafl && \
    cd LightFTP && \
    git checkout 5980ea1 && \
    patch -p1 < ${WORKDIR}/fuzzing.patch && \
    cd Source/Release && \
    AFL_USE_ASAN=1 CC=afl-clang-fast make clean all $MAKE_OPT

# Download and compile LightFTP for coverage analysis
RUN cd $WORKDIR/LightFTP-gcov && \
    git checkout 5980ea1 && \
    patch -p1 < ${WORKDIR}/gcov.patch && \
    cd Source/Release && \
    make CFLAGS="-fprofile-arcs -ftest-coverage" CPPFLAGS="-fprofile-arcs -ftest-coverage" CXXFLAGS="-fprofile-arcs -ftest-coverage" LDFLAGS="-fprofile-arcs -ftest-coverage" clean all $MAKE_OPT

RUN cd $WORKDIR/LightFTP-stateafl && \
    git checkout 5980ea1 && \
    patch -p1 < ${WORKDIR}/fuzzing.patch && \
    cd Source/Release && \
    CC=${STATEAFL}/afl-clang-fast make clean all $MAKE_OPT

####################################
# Build Testing Image with fuzzers:
# - aflnet
# - aflnwe
# - libaflnet
####################################
FROM libaflnet-rust:1.0.0

ARG GITHUB_TOKEN

USER ubuntu
WORKDIR /home/ubuntu

ENV http_proxy=$proxy
ENV https_proxy=$proxy

# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV AFLNWE="/home/ubuntu/aflnwe"
ENV STATEAFL="/home/ubuntu/stateafl"
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

RUN mkdir /home/ubuntu/ftpshare

# Copy fuzzing target from prebuilt image: lightftp:1.0.0
COPY --chown=ubuntu:ubuntu --from=lightftp ${WORKDIR}/LightFTP ${WORKDIR}/LightFTP
COPY --chown=ubuntu:ubuntu --from=lightftp ${WORKDIR}/LightFTP-gcov ${WORKDIR}/LightFTP-gcov

RUN cp ${AFLNET}/tutorials/lightftp/fftp.conf ${WORKDIR}/LightFTP/Source/Release/ && \
    cp ${AFLNET}/tutorials/lightftp/fftp.conf ${WORKDIR}/LightFTP-gcov/Source/Release && \
    cp ${AFLNET}/tutorials/lightftp/fftp.conf ${WORKDIR}/LightFTP-stateafl/Source/Release && \
    cp ${AFLNET}/tutorials/lightftp/ftpclean.sh ${WORKDIR}/LightFTP/Source/Release/ && \
    cp ${AFLNET}/tutorials/lightftp/ftpclean.sh ${WORKDIR}/LightFTP-gcov/Source/Release && \
    cp ${AFLNET}/tutorials/lightftp/ftpclean.sh ${WORKDIR}/LightFTP-stateafl/Source/Release && \
    cp -r ${AFLNET}/tutorials/lightftp/certificate /home/ubuntu

COPY --chown=ubuntu:ubuntu in-ftp ${WORKDIR}/in-ftp
COPY --chown=ubuntu:ubuntu ftp.dict ${WORKDIR}/ftp.dict
COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
COPY --chown=ubuntu:ubuntu clean.sh ${WORKDIR}/ftpclean
COPY --chown=ubuntu:ubuntu in-ftp-replay ${WORKDIR}/in-ftp-replay
COPY --chown=ubuntu:ubuntu run-stateafl.sh ${WORKDIR}/run-stateafl
COPY --chown=ubuntu:ubuntu blacklist.sh ${WORKDIR}/blacklist.sh