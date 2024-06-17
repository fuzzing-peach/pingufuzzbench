ARG proxy=http://172.17.0.1:7890
ARG MAKE_OPT
ARG LIBAFLNET_VERSION=1.1.0

####################################
# Build BFTPD Image
####################################
FROM libaflnet-afl:1.0.0 AS bftpd

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

# Set up Bftpd for fuzzing
COPY --chown=ubuntu:ubuntu bftpd-5.7.tar.gz ${WORKDIR}/bftpd-5.7.tar.gz
RUN cd ${WORKDIR} && \
    tar -zxvf bftpd-5.7.tar.gz && \
    cd ${WORKDIR}/bftpd && \
    patch -p1 < ${WORKDIR}/fuzzing.patch && \
    AFL_USE_ASAN=1 CC=afl-clang-fast make clean all $MAKE_OPT CFLAGS='-g -O2 -DHAVE_CONFIG_H -Wall -I. -DVERSION=\"$(VERSION)\" -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DPREFIX=\"$(prefix)\" -fcommon'

# Set up Bftpd for coverage analysis
RUN cd ${WORKDIR} && \
    mkdir ${WORKDIR}/bftpd-gcov && \
    tar -zxvf bftpd-5.7.tar.gz -C ${WORKDIR}/bftpd-gcov --strip-components=1 && \
    cd ${WORKDIR}/bftpd-gcov && \
    patch -p1 < ${WORKDIR}/gcov.patch && \
    make $MAKE_OPT \ 
        CFLAGS='-fprofile-arcs -ftest-coverage -g -O2 -DHAVE_CONFIG_H -Wall -I. -DVERSION=\"$(VERSION)\" -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DPREFIX=\"$(prefix)\" -fcommon' \ 
        CPPFLAGS="-fprofile-arcs -ftest-coverage" \
        CXXFLAGS="-fprofile-arcs -ftest-coverage" \
        LDFLAGS="-fprofile-arcs -ftest-coverage"

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

RUN mkdir /home/ubuntu/ftpshare && \
    chown -R ubuntu:ubuntu /home/ubuntu/ftpshare

# Copy fuzzing target from prebuilt image: lightftp:1.0.0
COPY --chown=ubuntu:ubuntu --from=bftpd ${WORKDIR}/bftpd ${WORKDIR}/bftpd
COPY --chown=ubuntu:ubuntu --from=bftpd ${WORKDIR}/bftpd-gcov ${WORKDIR}/bftpd-gcov

COPY --chown=ubuntu:ubuntu basic.conf ${WORKDIR}/
COPY --chown=ubuntu:ubuntu in-ftp ${WORKDIR}/in-ftp
COPY --chown=ubuntu:ubuntu ftp.dict ${WORKDIR}/ftp.dict
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
COPY --chown=ubuntu:ubuntu clean.sh ${WORKDIR}/clean
COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script

# Switch default user to root
USER root
WORKDIR /home/ubuntu
