FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy=${HTTP_PROXY}
ARG https_proxy=${HTTPS_PROXY}
ARG WOLFSSL_REF=59f4fa5

ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV http_proxy=${http_proxy}
ENV https_proxy=${https_proxy}

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    clang \
    lld \
    llvm \
    make \
    openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt

RUN git clone https://github.com/wolfssl/wolfssl.git /opt/wolfssl && \
    cd /opt/wolfssl && \
    git checkout ${WOLFSSL_REF} && \
    ./autogen.sh && \
    CC=clang CXX=clang++ \
    CFLAGS="-O0 -g -fsanitize=address" \
    CXXFLAGS="-O0 -g -fsanitize=address" \
    LDFLAGS="-fsanitize=address" \
    ./configure \
      --enable-static \
      --enable-shared=no \
      --enable-tls13 \
      --enable-session-ticket \
      --enable-opensslextra \
      --enable-alpn \
      --enable-ocsp \
      --enable-ocspstapling \
      --enable-ocspstapling2 \
      --enable-crl \
      --enable-crl-monitor \
      --enable-ech \
      --enable-earlydata \
      --enable-psk && \
    make -j"$(nproc)" examples/server/server examples/client/client

COPY run_repro.sh /opt/run_repro.sh
RUN chmod +x /opt/run_repro.sh

ENTRYPOINT ["/opt/run_repro.sh"]
