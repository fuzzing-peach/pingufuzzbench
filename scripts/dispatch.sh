#!/usr/bin/env bash

set -e
set -o pipefail

cd $(dirname $0)
cd ..
source scripts/utils.sh

# Disable ASLR in the current shell
# But this is not permitted
# setarch `uname -m` -R /bin/bash

function in_subshell() {
    (
        set -eo pipefail
        BASE=${HOME}/profuzzbench
        cmd="$@"
        echo "[+] Running in subshell: $cmd"
        if [[ -n "$PFB_CPU_CORE" ]]; then
            echo "[+] Running in cpu core: $PFB_CPU_CORE"
            taskset -c $PFB_CPU_CORE bash -c "cd ${HOME}; source $BASE/$target_config; source $BASE/scripts/utils.sh; $cmd"
        else
            echo "[+] CPU_CORE is not set, running in any core"
            bash -c "cd ${HOME}; source $BASE/$target_config; source $BASE/scripts/utils.sh; $cmd"
        fi
    ) || exit 1
}

if [[ $# -lt 1 ]]; then
    echo "[!] Not enough arguments! TODO: <path> [fuzzer]"
    echo "[!] <path>: TLS/openssl etc."
    exit 1
fi

target=$1
if [[ ! -d "subjects/${target}" ]]; then
    echo "[!] Invalid target: $target"
    exit 1
fi

target_config="subjects/$target/config.sh"
if [[ ! -f "$target_config" ]]; then
    echo "[!] Config could not be found at: $target_config"
    exit 1
fi

cmd=${2-"build"}
# cmd is checkout
case $cmd in
checkout)
    source $target_config
    shift 2
    in_subshell checkout "$@"
    exit 0
    ;;
*) ;;
esac

# cmd is build/run
fuzzer=${3-"all"}
shift 3
case $fuzzer in
deps)
    # build deps
    if ! grep -q "source $target_config" ~/.zshrc; then
        echo "source $(pwd)/$target_config" >> ~/.zshrc
        echo "source $(pwd)/scripts/utils.sh" >> ~/.zshrc
    fi
    if ! grep -q "source $target_config" ~/.bashrc; then
        echo "source $(pwd)/$target_config" >> ~/.bashrc
        echo "source $(pwd)/scripts/utils.sh" >> ~/.bashrc
    fi

    source $target_config
    in_subshell install_dependencies "$@"
    ;;
pingu)
    # Pingu is the name of my fuzzer :)
    if [[ "$cmd" == "build" ]]; then
        (
            # build consumer
            source $target_config
            # build_pingu_consumer $flags(is written to the environment variable FLAGS)
            in_subshell build_pingu_consumer
        )
        (
            # build generator
            # $GENERATOR is in the form of OpenSSL, WolfSSL, etc.
            if [[ -n $GENERATOR ]]; then
                # generator is in the form of TLS/OpenSSL, TLS/WolfSSL, etc.
                generator=${target%/*}/$GENERATOR
            else
                # generator is the same as target
                generator=${target}
            fi
            source "subjects/$generator/config.sh"
            in_subshell build_pingu_generator
        )
    else
        # run generator-consumer
        source $target_config
        # run_pingu $generator $timeout ...(other args)
        in_subshell run_pingu "$@"
    fi
    ;;
ft)
    # FT-Net: https://github.com/fuzztruction/fuzztruction-net
    # args: scripts/dispatch.sh ${TARGET} build ft ${GENERATOR}
    # when ${GENERATOR} is not specified, it is treated the same as ${TARGET}
    # ${GENERATOR} is the implmentation name like OpenSSL
    if [[ "$cmd" == "build" ]]; then
        (
            # build consumer
            source $target_config
            # ignore the ${GENERATOR}
            in_subshell build_ft_consumer
        )
        (
            # build generator
            if [[ -n $GENERATOR ]]; then
                generator=${target%/*}/$GENERATOR
            else
                generator=${target}
            fi
            source "subjects/$generator/config.sh"
            in_subshell build_ft_generator
        )
    else
        # run generator-consumer
        source $target_config
        # run_ft $generator $timeout ...(other args)
        in_subshell run_ft "$@"
    fi
    ;;
aflnet)
    source $target_config
    in_subshell "$cmd"_aflnet "$@"
    ;;
stateafl)
    # StateAFL: https://github.com/stateafl/stateafl
    source $target_config
    in_subshell "$cmd"_stateafl "$@"
    ;;
sgfuzz)
    # SGFuzz: https://github.com/bajinsheng/SGFuzz
    # The configuration steps could also be referenced by https://github.com/fuzztruction/fuzztruction-net/blob/main/Dockerfile
    source $target_config
    in_subshell "$cmd"_sgfuzz "$@"
    ;;
quicfuzz)
    # Build vanilla version
    # Vanilla means the true original version, without any instrumentation, hooking and analysis.
    source $target_config
    in_subshell "$cmd"_quicfuzz "$@"
    ;;
gcov)
    # Build the gcov version, which is used to be computed coverage upon.
    source $target_config
    in_subshell build_gcov "$@"
    ;;
all)
    echo "[!] Not implemented for 'all'"
    ;;
*)
    echo "[!] Invalid fuzzer $fuzzer"
    exit 1
    ;;
esac
