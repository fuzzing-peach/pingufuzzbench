#!/usr/bin/env bash

cd $(dirname $0)
cd ..
source scripts/utils.sh

args=$(get_args_before_double_dash "$@")
docker_args=$(get_args_after_double_dash "$@")

opt_args=$(getopt -o f: -l fuzzer: --name "$0" -- "${args[@]}")
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

container_name=$(echo "pingu-env-${fuzzer}" | tr 'A-Z' 'a-z')
image_name=$(echo "pingu-env-${fuzzer}:latest" | tr 'A-Z' 'a-z')

echo "container_name: ${container_name}"
echo "image_name: ${image_name}"

if ! docker image inspect ${image_name} >/dev/null 2>&1; then
    echo "[+] ${image_name} image is not existed, please build it using ./scripts/build-env.sh first"
    exit 1
fi

echo "[+] Checking if pingu-dev container exists"
if ! docker ps -a | grep -q ${container_name}; then
    echo "[+] ${container_name} container is not existed, start running container..."
    cmd="docker run -it -d \
            --cap-add=SYS_ADMIN --cap-add=SYS_RAWIO --cap-add=SYS_PTRACE \
            --security-opt seccomp=unconfined \
            --security-opt apparmor=unconfined \
            -v $(pwd):/home/user/profuzzbench \
            --mount type=tmpfs,destination=/tmp,tmpfs-mode=777 \
            --ulimit msgqueue=2097152000 \
            --shm-size=64G \
            --name ${container_name} \
            ${docker_args}
            ${image_name} tail -f /dev/null"
    echo "[+] Executing: $cmd"
    eval $cmd
    exit 0
else
    echo "[+] ${container_name} is running, enter container..."
    docker exec -it ${container_name} /bin/bash
fi
