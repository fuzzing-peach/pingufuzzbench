#!/usr/bin/env bash

set -e
set -o pipefail
cd $(dirname $0)
cd ..
source scripts/utils.sh

opt_args=$(getopt -o f: -l fuzzer: --name "$0" -- "$@")
if [ $? != 0 ]; then
    log_error "[!] Error in parsing shell arguments."
    exit 1
fi

eval set -- "${opt_args}"
while true; do
    case "$1" in
    -f | --fuzzer)
        fuzzer="$2"
        fuzzer=$(echo "$fuzzer" | sed 's/^ *//;s/ *$//')
        shift 2
        ;;
    *)
        break
        ;;
    esac
done

if [[ -z "$fuzzer" ]]; then
    log_error "[!] Fuzzer argument is required. Please specify a fuzzer using -f or --fuzzer."
    exit 1
fi

image_name=$(echo "pingu-env-${fuzzer}:latest" | tr 'A-Z' 'a-z')

log_success "[+] Pulling prebuilt image: ${image_name}"

docker pull ghcr.io/fuzzing-peach/pingu-env-${fuzzer}:latest

log_success "[+] Pulled prebuilt image successfully: ${image_name}"

docker tag ghcr.io/fuzzing-peach/pingu-env-${fuzzer}:latest pingu-env-${fuzzer}:latest
docker rmi ghcr.io/fuzzing-peach/pingu-env-${fuzzer}:latest