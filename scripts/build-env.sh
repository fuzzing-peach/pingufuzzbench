#!/usr/bin/env bash

export TERM=xterm-256color

set -e
set -o pipefail
cd $(dirname $0)
cd ..
source scripts/utils.sh

parse_args() {
    local OPTIND
    while getopts ":f:" opt; do
        case $opt in
            f)
                fuzzer="$OPTARG"
                ;;
            \?)
                echo "Invalid option: -$OPTARG" >&2
                ;;
            :)
                echo "Option -$OPTARG requires an argument." >&2
                exit 1
                ;;
        esac
    done
}

# Get arguments before double dash
args=$(get_args_before_double_dash "$@")

eval "parse_args $args"

if [[ -n "$fuzzer" ]]; then
    fuzzer=$(echo "$fuzzer" | tr '[:upper:]' '[:lower:]')
    image="pingu-env-${fuzzer}"
    dockerfile="Dockerfile-env-${fuzzer}"
fi

log_success "[+] Build mode: ${profile}"
docker_args=$(get_args_after_double_dash "$@")
log_success "[+] Building docker image: ${image}:latest"
# If http proxy is required, passing:
# --build-arg HTTP_PROXY=http://172.17.0.1:7890 --build-arg HTTPS_PROXY=http://172.17.0.1:7890 
# If needs to add dns server, passing:
# --build-arg DNS_SERVER=9.9.9.9
DOCKER_BUILDKIT=1 docker build --build-arg USER_ID="$(id -u)" --build-arg GROUP_ID="$(id -g)" -f scripts/${dockerfile} $docker_args . -t ${image}:latest
if [[ $? -ne 0 ]]; then
    log_error "[!] Error while building the docker image: ${image}:latest"
    exit 1
else
    log_success "[+] Docker image successfully built: ${image}:latest"
fi

exit 0