#!/usr/bin/env bash

set -e
set -o pipefail
cd $(dirname $0)
cd ..
source scripts/utils.sh

# Parameters after -- is passed directly to the docker build
args=($(get_args_before_double_dash "$@"))
docker_args=$(get_args_after_double_dash "$@")

opt_args=$(getopt -o f:t:v: -l fuzzer:,target:,version:,generator:,flags: --name "$0" -- "${args[@]}")
if [ $? != 0 ]; then
    log_error "[!] Error in parsing shell arguments."
    exit 1
fi

eval set -- "${opt_args}"
while true; do
    case "$1" in
    -f | --fuzzer)
        fuzzer="$2"
        shift 2
        ;;
    -t | --target)
        target="$2"
        shift 2
        ;;
    -v | --version)
        if [[ -n "$2" && "$2" != "--" ]]; then
            version="$2"
            shift 2
        else
            log_error "[!] Option -v|--version requires a non-empty value."
            exit 1
        fi
        ;;
    --generator)
        generator="$2"
        shift 2
        ;;
    --flags)
        flags="$2"
        shift 2
        ;;
    *)
        break
        ;;
    esac
done

if [[ -n "$generator" && "$fuzzer" != "ft" && "$fuzzer" != "pingu" ]]; then
    log_error "[!] Argument --generator is only allowed when --fuzzer is ft or pingu"
    exit 1
fi

protocol=${target%/*}
impl=${target##*/}
if [[ -z "$generator" ]]; then
    image_name=$(echo "pingu-${fuzzer}-${protocol}-${impl}:${version:-latest}" | tr 'A-Z' 'a-z')
else
    # image name is like: pingu-ft/pingu-OpenSSL-TLS-OpenSSL:latest
    # or: pingu-ft/pingu-OpenSSL-TLS:latest
    image_name=$(echo "pingu-${fuzzer}-${generator}-${protocol}-${impl}:${version:-latest}" | tr 'A-Z' 'a-z')
fi

# Check if pingu-env-${fuzzer} docker image exists
env_image_name="pingu-env-${fuzzer}:latest"
if ! docker image inspect ${env_image_name} >/dev/null 2>&1; then
    env_image_name="pingu-env:latest"
fi

# Set the base image argument for the Dockerfile
docker_args="--build-arg BASE_IMAGE=${env_image_name} ${docker_args}"

log_success "[+] Building docker image: ${image_name}, from ${env_image_name}"
log_success "[+] Docker build args: ${docker_args}"
# If http proxy is required, passing:
# --build-arg HTTP_PROXY=http://172.17.0.1:7890 --build-arg HTTPS_PROXY=http://172.17.0.1:7890
# If needs to add dns server, passing: --build-arg DNS_SERVER=9.9.9.9
# --build-arg DNS_SERVER=9.9.9.9
cmd="docker build \
    --build-arg FUZZER=$fuzzer \
    --build-arg TARGET=$target \
    --build-arg VERSION=$version \
    --build-arg GENERATOR=$generator \
    --build-arg USER_UID="$(id -u)" \
    --build-arg USER_GID="$(id -g)" \
    -f scripts/Dockerfile \
    $docker_args . \
    -t $image_name"
log_success "[+] Running command: ${cmd}"
DOCKER_BUILDKIT=1 ${cmd}
if [[ $? -ne 0 ]]; then
    log_error "[!] Error while building the docker image: $image_name"
    exit 1
else
    log_success "[+] Docker image successfully built: $image_name"
fi

exit 0
