FROM rust:bullseye
LABEL maintainer="Zou Dikai"

ARG GITHUB_TOKEN
ARG proxy=http://172.17.0.1:7890
# Import environment variable to pass as parameter to make (e.g., to make parallel builds with -j)
ARG MAKE_OPT

ENV http_proxy=$proxy
ENV https_proxy=$proxy

RUN apt install apt-transport-https ca-certificates

RUN sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list && apt clean

# LLVM-11
RUN apt-get update && apt-get install -y --no-install-recommends wget ca-certificates gnupg2 && rm -rf /var/lib/apt/lists
RUN echo deb http://apt.llvm.org/bullseye/ llvm-toolchain-bullseye-11 main >> /etc/apt/sources.list
RUN wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | apt-key add - 

# Install common dependencies
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    apt-utils git build-essential curl libgnutls28-dev libssl-dev sudo libtool libtool-bin libglib2.0-dev bison flex automake python3 python3-dev python3-setuptools python-is-python3 libpixman-1-dev gcc-9-plugin-dev cgroup-tools \
    clang-11 clang-tools-11 libc++1-11 libc++-11-dev libc++abi1-11 libc++abi-11-dev libclang1-11 libclang-11-dev libclang-common-11-dev libclang-cpp11 libclang-cpp11-dev liblld-11 liblld-11-dev liblldb-11 liblldb-11-dev libllvm11 libomp-11-dev libomp5-11 lld-11 lldb-11 python3-lldb-11 llvm-11 llvm-11-dev llvm-11-runtime llvm-11-tools \
    rsync autopoint bison gperf autoconf texinfo gettext \
    libtool pkg-config libz-dev python3-pip \
    awscli openssh-server ncat netcat openssl \
    vim nano screen htop man wget httpie bash-completion ripgrep \
    gdb byobu \
    graphviz-dev libcap-dev libpcap-dev \
    iputils-ping telnet net-tools \
    strace \
    && rm -rf /var/lib/apt/lists

# AFL
###########
RUN update-alternatives --install /usr/bin/clang clang $(which clang-11) 1 && \
    update-alternatives --install /usr/bin/clang++ clang++ $(which clang++-11) 1 && \
    update-alternatives --install /usr/bin/llvm-config llvm-config $(which llvm-config-11) 1 && \
    update-alternatives --install /usr/bin/llvm-symbolizer llvm-symbolizer $(which llvm-symbolizer-11) 1 && \
    update-alternatives --install /usr/bin/llvm-cov llvm-cov $(which llvm-cov-11) 1 && \
    update-alternatives --install /usr/bin/llvm-profdata llvm-profdata $(which llvm-profdata-11) 1

RUN pip3 install gcovr==4.2

# Users & SSH
##############
# Add a new user ubuntu, pass: ubuntu
RUN groupadd ubuntu && \
    useradd -rm -d /home/ubuntu -s /bin/bash -g ubuntu -G sudo -u 1000 ubuntu -p "$(openssl passwd -1 ubuntu)" && \
    echo "ubuntu ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

RUN chmod 777 /tmp

# Use ubuntu as default username
USER ubuntu
WORKDIR /home/ubuntu

RUN git config --global http.proxy $proxy && \
    git config --global https.proxy $proxy && \
    git config --global http.version HTTP/1.1 

# Set up fuzzers
# aflnet
##############
RUN git clone https://github.com/profuzzbench/aflnet.git && \
    cd aflnet && \
    make clean all $MAKE_OPT && \
    cd llvm_mode && make $MAKE_OPT

# aflnwe
##############
RUN git clone https://github.com/profuzzbench/aflnwe.git && \
    cd aflnwe && \
    make clean all $MAKE_OPT && \
    cd llvm_mode && make $MAKE_OPT

# libaflnet
##############
RUN rustup default nightly

RUN git clone https://Kherrisan:$GITHUB_TOKEN@github.com/Kherrisan/libaflnet.git && \
    cd libaflnet && \
    git checkout v1.1.0 && \
    cargo build -Z unstable-options --release --out-dir /home/ubuntu/libaflnet


# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV PATH="${PATH}:${AFLNET}:/home/ubuntu/.local/bin:${WORKDIR}"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1 \
    AFL_NO_AFFINITY=1

RUN mkdir $WORKDIR

# Set up environment variables for ASAN
env ASAN_OPTIONS='abort_on_error=1:symbolize=0:detect_leaks=0:detect_stack_use_after_return=1:detect_container_overflow=0:poison_array_cookie=0:malloc_fill_byte=0:max_malloc_fill_size=16777216'

# Use "--enable-devel=...:coredump:stacktrace" for debugging

# Set up ProFTPD for fuzzing
RUN cd ${WORKDIR} && \
    git clone --depth=1 https://github.com/proftpd/proftpd.git && \
    cd proftpd && \
    git fetch --unshallow && \
    git checkout 4017eff8 && \
    CC="afl-clang-fast" CXX="afl-clang-fast++" ./configure --enable-devel=nodaemon:nofork && \
    AFL_USE_ASAN=1 make $MAKE_OPT

# Set up ProFTPD for coverage analysis
RUN cd ${WORKDIR} && \
    git clone --depth=1  https://github.com/proftpd/proftpd.git proftpd-gcov && \
    cd proftpd-gcov && \
    git fetch --unshallow && \
    git checkout 4017eff8 && \
    CFLAGS="-fprofile-arcs -ftest-coverage" CPPFLAGS="-fprofile-arcs -ftest-coverage" CXXFLAGS="-fprofile-arcs -ftest-coverage" LDFLAGS="-fprofile-arcs -ftest-coverage" ./configure --enable-devel=nodaemon:nofork && \
    make $MAKE_OPT


COPY --chown=ubuntu:ubuntu basic.conf ${WORKDIR}/
COPY --chown=ubuntu:ubuntu in-ftp ${WORKDIR}/in-ftp
COPY --chown=ubuntu:ubuntu ftp.dict ${WORKDIR}/ftp.dict
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
COPY --chown=ubuntu:ubuntu clean.sh ${WORKDIR}/clean
COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script

RUN mkdir /home/ubuntu/ftpshare && \
    chown -R ubuntu:ubuntu /home/ubuntu/ftpshare


# Switch default user to root
USER root
WORKDIR /home/ubuntu