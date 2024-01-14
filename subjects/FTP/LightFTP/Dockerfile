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
# Packages
##############
# by line:
#   build and afl
#   llvm-11 (for afl-clang-lto)
#   date challenge
#   libxml2 challenge
#   server/entrypoint
#   user tools
#   debugging tools
RUN apt-get update && apt-get install -y \
    git build-essential curl libgnutls28-dev libssl-dev sudo libtool libtool-bin libglib2.0-dev bison flex automake python3 python3-dev python3-setuptools python-is-python3 libpixman-1-dev gcc-9-plugin-dev cgroup-tools \
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

USER ubuntu
WORKDIR /home/ubuntu

RUN git config --global http.proxy $proxy && \
    git config --global https.proxy $proxy

# Set up fuzzers
# aflnet
##############
RUN git clone https://github.com/Kherrisan/aflnet.git && \
    cd aflnet && \
    make clean all $MAKE_OPT && \
    cd llvm_mode && make $MAKE_OPT

# aflnwe
##############
RUN git clone https://github.com/Kherrisan/aflnwe.git && \
    cd aflnwe && \
    make clean all $MAKE_OPT && \
    cd llvm_mode && make $MAKE_OPT

# libaflnet
##############
RUN rustup default nightly
RUN git clone https://Kherrisan:$GITHUB_TOKEN@github.com/Kherrisan/libaflnet.git && \
    cd libaflnet && \
    cargo build

# Set up environment variables for AFLNet
ENV WORKDIR="/home/ubuntu/experiments"
ENV AFLNET="/home/ubuntu/aflnet"
ENV LIBAFLNET="/home/ubuntu/libaflnet"
ENV PATH="${PATH}:${AFLNET}:/home/ubuntu/.local/bin:${WORKDIR}:${LIBAFLNET}/target/debug"
ENV AFL_PATH="${AFLNET}"
ENV AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 \
    AFL_SKIP_CPUFREQ=1 \
    AFL_NO_AFFINITY=1

RUN mkdir $WORKDIR

COPY --chown=ubuntu:ubuntu fuzzing.patch ${WORKDIR}/fuzzing.patch
COPY --chown=ubuntu:ubuntu gcov.patch ${WORKDIR}/gcov.patch

# Set up environment variables for ASAN
env ASAN_OPTIONS='abort_on_error=1:symbolize=0:detect_leaks=0:detect_stack_use_after_return=1:detect_container_overflow=0:poison_array_cookie=0:malloc_fill_byte=0:max_malloc_fill_size=16777216'

# Download and compile LightFTP for fuzzing
RUN cd $WORKDIR && \
    git clone https://github.com/hfiref0x/LightFTP.git && \
    cd LightFTP && \
    git checkout 5980ea1 && \
    patch -p1 < ${WORKDIR}/fuzzing.patch && \
    cd Source/Release && \
    AFL_USE_ASAN=1 CC=afl-clang-fast make clean all $MAKE_OPT

# Set up LightFTP for fuzzing
RUN cd ${WORKDIR}/LightFTP/Source/Release && \
    cp ${AFLNET}/tutorials/lightftp/fftp.conf ./ && \
    cp ${AFLNET}/tutorials/lightftp/ftpclean.sh ./ && \
    cp -r ${AFLNET}/tutorials/lightftp/certificate /home/ubuntu && \
    mkdir /home/ubuntu/ftpshare

# Download and compile LightFTP for coverage analysis
RUN cd $WORKDIR && \
    git clone https://github.com/hfiref0x/LightFTP.git LightFTP-gcov && \
    cd LightFTP-gcov && \
    git checkout 5980ea1 && \
    patch -p1 < ${WORKDIR}/gcov.patch && \
    cd Source/Release && \
    make CFLAGS="-fprofile-arcs -ftest-coverage" CPPFLAGS="-fprofile-arcs -ftest-coverage" CXXFLAGS="-fprofile-arcs -ftest-coverage" LDFLAGS="-fprofile-arcs -ftest-coverage" clean all $MAKE_OPT

# Set up LightFTP for coverage analysis
RUN cd ${WORKDIR}/LightFTP-gcov/Source/Release && \
    cp ${AFLNET}/tutorials/lightftp/fftp.conf ./ && \
    cp ${AFLNET}/tutorials/lightftp/ftpclean.sh ./


COPY --chown=ubuntu:ubuntu in-ftp ${WORKDIR}/in-ftp
COPY --chown=ubuntu:ubuntu ftp.dict ${WORKDIR}/ftp.dict
COPY --chown=ubuntu:ubuntu cov_script.sh ${WORKDIR}/cov_script
COPY --chown=ubuntu:ubuntu run.sh ${WORKDIR}/run
COPY --chown=ubuntu:ubuntu clean.sh ${WORKDIR}/ftpclean

USER ubuntu
