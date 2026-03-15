#!/usr/bin/env bash

if [ -z "${MAKE_OPT+x}" ] || [ -z "${MAKE_OPT}" ]; then
    MAKE_OPT="-j$(nproc)"
fi

LSQUIC_BASELINE="v4.4.2"
BORINGSSL_BASELINE="75a1350"
NGTCP2_BASELINE="28d3126"
WOLFSSL_BASELINE="b3f08f3"
NGHTTP3_BASELINE="21526d7"

if [ -d "${HOME}/profuzzbench" ]; then
    PFB_ROOT="${HOME}/profuzzbench"
else
    PFB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

function resolve_target_root {
    local root="${PFB_ROOT}/target"
    if [ ! -d "${root}" ]; then
        root="${HOME}/target"
    fi
    echo "${root}"
}

function git_clone_retry {
    local url="$1"
    local dst="$2"
    local retries="${3:-3}"
    local recursive="${4:-0}"
    local i=1
    while [ "${i}" -le "${retries}" ]; do
        rm -rf "${dst}"
        if [ "${recursive}" = "1" ]; then
            if git clone --filter=blob:none --recursive "${url}" "${dst}"; then
                return 0
            fi
        else
            if git clone --filter=blob:none "${url}" "${dst}"; then
                return 0
            fi
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

function clone_boringssl_retry {
    local dst="$1"
    local retries="${2:-3}"
    if git_clone_retry https://boringssl.googlesource.com/boringssl "${dst}" "${retries}" 0; then
        return 0
    fi
    git_clone_retry https://github.com/google/boringssl.git "${dst}" "${retries}" 0
}

function maybe_commit_patch {
    local msg="$1"
    if ! git diff --quiet; then
        git add .
        git commit -m "${msg}"
    fi
}

function checkout {
    local target_ref="${1:-$LSQUIC_BASELINE}"
    mkdir -p .git-cache repo

    if [ ! -d ".git-cache/lsquic/.git" ]; then
        git_clone_retry https://github.com/litespeedtech/lsquic.git .git-cache/lsquic || return 1
    else
        pushd .git-cache/lsquic >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/lsquic
    cp -r .git-cache/lsquic repo/lsquic
    pushd repo/lsquic >/dev/null
    git checkout "${LSQUIC_BASELINE}"
    git submodule update --init --recursive
    git apply ${PFB_ROOT}/subjects/QUIC/lsquic/lsquic-time.patch || return 1
    maybe_commit_patch "apply lsquic deterministic time patch"
    patch_commit=$(git rev-parse HEAD)
    if [ "${target_ref}" != "${LSQUIC_BASELINE}" ]; then
        git checkout "${target_ref}"
        git cherry-pick "${patch_commit}" || return 1
    fi
    popd >/dev/null

    if [ ! -d ".git-cache/boringssl/.git" ]; then
        clone_boringssl_retry .git-cache/boringssl || return 1
    else
        pushd .git-cache/boringssl >/dev/null
        git fetch --all --tags
        popd >/dev/null
    fi
    rm -rf repo/boringssl
    cp -r .git-cache/boringssl repo/boringssl
    pushd repo/boringssl >/dev/null
    git checkout "${BORINGSSL_BASELINE}" || true
    git apply ${PFB_ROOT}/subjects/QUIC/lsquic/lsquic-random.patch || return 1
    maybe_commit_patch "apply boringssl deterministic random patch"
    popd >/dev/null

    if [ ! -d ".git-cache/ngtcp2/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/ngtcp2 .git-cache/ngtcp2 || return 1
    fi
    rm -rf repo/ngtcp2
    cp -r .git-cache/ngtcp2 repo/ngtcp2
    pushd repo/ngtcp2 >/dev/null
    git checkout "${NGTCP2_BASELINE}"
    popd >/dev/null

    if [ ! -d ".git-cache/wolfssl/.git" ]; then
        git_clone_retry https://github.com/wolfSSL/wolfssl .git-cache/wolfssl || return 1
    fi
    rm -rf repo/wolfssl
    cp -r .git-cache/wolfssl repo/wolfssl
    pushd repo/wolfssl >/dev/null
    git checkout "${WOLFSSL_BASELINE}"
    popd >/dev/null

    if [ ! -d ".git-cache/nghttp3/.git" ]; then
        git_clone_retry https://github.com/ngtcp2/nghttp3 .git-cache/nghttp3 || return 1
    fi
    rm -rf repo/nghttp3
    cp -r .git-cache/nghttp3 repo/nghttp3
    pushd repo/nghttp3 >/dev/null
    git checkout "${NGHTTP3_BASELINE}"
    git submodule update --init --recursive
    popd >/dev/null
}

function install_dependencies {
    sudo mkdir -p /var/lib/apt/lists/partial
    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libevent-dev cmake golang-go
    sudo rm -rf /var/lib/apt/lists/*
}

function replay { echo "Not implemented"; }
function build_aflnet { echo "Not implemented"; }
function run_aflnet { echo "Not implemented"; }
function build_sgfuzz { echo "Not implemented"; }
function run_sgfuzz { echo "Not implemented"; }
function build_ft_generator { echo "Not implemented"; }
function build_ft_consumer { echo "Not implemented"; }
function run_ft { echo "Not implemented"; }
function build_quicfuzz { echo "Not implemented"; }
function run_quicfuzz { echo "Not implemented"; }
function build_stateafl { echo "Not implemented"; }
function run_stateafl { echo "Not implemented"; }
function build_asan { echo "Not implemented"; }
function build_gcov { echo "Not implemented"; }
function cleanup_artifacts { echo "No artifacts"; }
