ARG proxy=http://172.17.0.1:7890
ARG MAKE_OPT
ARG LIBAFLNET_VERSION=1.1.0

####################################
# Build PureFTPD Image
####################################
FROM libaflnet-afl:1.0.0 AS pureftpd

ENV http_proxy=$proxy
ENV https_proxy=$proxy

# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV LIBAFLNET="/home/ubuntu/libaflnet"
ENV PATH="${PATH}:${AFLNET}:/home/ubuntu/.local/bin:${WORKDIR}"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1

USER root
RUN apt -y install automake
USER ubuntu

RUN mkdir $WORKDIR

COPY --chown=ubuntu:ubuntu fuzzing.patch ${WORKDIR}/fuzzing.patch
COPY --chown=ubuntu:ubuntu gcov.patch ${WORKDIR}/gcov.patch

# Set up environment variables for ASAN
env ASAN_OPTIONS='abort_on_error=1:symbolize=0:detect_leaks=0:detect_stack_use_after_return=1:detect_container_overflow=0:poison_array_cookie=0:malloc_fill_byte=0:max_malloc_fill_size=16777216'

# Set up PureFTPD for fuzzing
RUN cd ${WORKDIR} && \
    git clone https://github.com/jedisct1/pure-ftpd.git && \
    cp -r pure-ftpd pure-ftpd-gcov && \
    cd pure-ftpd && \
    git checkout c21b45f && \
    patch -p1 < ${WORKDIR}/fuzzing.patch && \
    ./autogen.sh && \
    CC="afl-clang-fast" CXX="afl-clang-fast++" CFLAGS="-fsanitize=address -g -O0" CXXFLAGS="-fsanitize=address -g -O0" LDFLAGS="-fsanitize=address" ./configure --without-privsep -without-capabilities && \
    make $MAKE_OPT

# Set up PureFTPD for coverage analysis
RUN cd ${WORKDIR}/pure-ftpd-gcov && \
    git checkout c21b45f && \
    patch -p1 < ${WORKDIR}/gcov.patch && \
    ./autogen.sh && \
    CFLAGS="-fprofile-arcs -ftest-coverage" CPPFLAGS="-fprofile-arcs -ftest-coverage" CXXFLAGS="-fprofile-arcs -ftest-coverage" LDFLAGS="-fprofile-arcs -ftest-coverage" ./configure --without-privsep -without-capabilities && \
    make $MAKE_OPT

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

# Copy fuzzing target from prebuilt image: lightftp:1.0.0
COPY --chown=ubuntu:ubuntu --from=pureftpd ${WORKDIR}/pure-ftpd ${WORKDIR}/pure-ftpd
COPY --chown=ubuntu:ubuntu --from=pureftpd ${WORKDIR}/pure-ftpd-gcov ${WORKDIR}/pure-ftpd-gcov

COPY --chown=ubuntu:ubuntu in-ftp ${WORKDIR}/in-ftp
COPY --chown=ubuntu:ubuntu ftp.dict ${WORKDIR}/ftp.dict
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
COPY --chown=ubuntu:ubuntu clean.sh ${WORKDIR}/clean
COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script

# Switch default user to root
USER root
WORKDIR /home/ubuntu

RUN useradd -rm -d /home/fuzzing -s /bin/bash -g ubuntu -G sudo -u 1001 fuzzing -p "$(openssl passwd -1 fuzzing)"
