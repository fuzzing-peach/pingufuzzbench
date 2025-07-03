ARG BASE_IMAGE=pingu-env:latest

FROM ${BASE_IMAGE}

USER user
ENV HOME=/home/user

ARG MAKE_OPT="-j4"
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy=${HTTP_PROXY}
ARG https_proxy=${HTTP_PROXY}
ENV no_proxy="localhost,127.0.0.1,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8"
ENV NO_PROXY=${no_proxy}

ARG FUZZER
ARG TARGET
ARG VERSION
ARG GENERATOR
ARG CARGO_BUILD_JOBS="4"
ENV CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS}
ENV FUZZER=${FUZZER}
ENV TARGET=${TARGET}
ENV VERSION=${VERSION}
ENV GENERATOR=${GENERATOR}
ENV TERM=xterm

RUN --mount=type=bind,source=.,target=/home/user/profuzzbench \
    bash ${HOME}/profuzzbench/scripts/dispatch.sh ${TARGET} build deps
RUN --mount=type=bind,source=.,target=/home/user/profuzzbench \
    bash ${HOME}/profuzzbench/scripts/dispatch.sh ${TARGET} checkout ${VERSION}
RUN --mount=type=bind,source=.,target=/home/user/profuzzbench \
    bash ${HOME}/profuzzbench/scripts/dispatch.sh ${TARGET} build gcov
RUN --mount=type=bind,source=.,target=/home/user/profuzzbench \
    bash ${HOME}/profuzzbench/scripts/dispatch.sh ${TARGET} build ${FUZZER}