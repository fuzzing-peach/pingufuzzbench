#!/usr/bin/env bash

cd $(dirname $0)
cd ..
source scripts/utils.sh

args=($(get_args_before_double_dash "$@"))
docker_args=$(get_args_after_double_dash "$@")

# Check if the pingu-eval image exists, if not, build it
if ! docker image inspect pingu-eval:latest > /dev/null 2>&1; then
    log_success "[+] pingu-eval image does not exist. Building now..."
    cmd="DOCKER_BUILDKIT=1 docker build --build-arg USER_ID="$(id -u)" --build-arg GROUP_ID="$(id -g)" -t pingu-eval:latest $docker_args -f scripts/Dockerfile-eval ."
    echo "[+] Building pingu-eval image with command: $cmd"
    eval $cmd
    if [[ $? -ne 0 ]]; then
        log_error "[!] Error while building the pingu-eval image"
        exit 1
    else
        log_success "[+] pingu-eval image successfully built"
    fi
else
    log_success "[+] pingu-eval image already exists"
fi

# Check if the pingu-eval container exists, if not, run a container with tail -f /dev/null
if ! docker container inspect pingu-eval > /dev/null 2>&1; then
    log_success "[+] pingu-eval container does not exist. Running now..."
    docker run -d --name pingu-eval -v $(pwd):/home/user/profuzzbench --network=host pingu-eval:latest
    if [[ $? -ne 0 ]]; then
        log_error "[!] Error while running the pingu-eval container"
        exit 1
    else
        log_success "[+] pingu-eval container successfully started, jupyter lab is running at http://localhost:38888"
    fi
else
    log_success "[+] pingu-eval container already exists"
fi

opt_args=$(getopt -o f:t:v:o:c: -l fuzzer:,target:,version:,generator:,output:,count:,summary --name "$0" -- "${args[@]}")
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
    -o | --output)
        output="$2"
        shift 2
        ;;
    -c | --count)
        count="$2"
        shift 2
        ;;
    --summary)
        summary=true
        shift
        ;;
    *)
        break
        ;;
    esac
done

if [[ -z "$version" ]]; then
    log_error "[!] --version is required"
    exit 1
fi

if [[ -z "$output" ]]; then
    output="."
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

output_tar_prefix="${output}/pingu-${fuzzer}-${protocol}-${impl}"
log_info "[+] Searching for output folders matching: ${output_tar_prefix}*"
output_folders=($(ls -d ${output_tar_prefix}* 2>/dev/null))
# Filter out non-directory entries
output_folders=($(for folder in "${output_folders[@]}"; do
    if [[ -d "$folder" ]]; then
        echo "$folder"
    fi
done))
if [[ ${#output_folders[@]} -eq 0 ]]; then
    log_error "[!] No output folders found matching the prefix: ${output_tar_prefix}"
    exit 1
fi

if [[ -n "$count" ]]; then
    output_folders=("${output_folders[@]:0:$count}")
fi

log_success "[+] Found output folders: ${output_folders[*]}"

coverage_files=()
for output_folder in "${output_folders[@]}"; do
    coverage_file="${output_folder}/coverage.csv"
    coverage_files+=("${coverage_file}")
done

if [[ -n "$summary" ]]; then
    docker exec -w /home/user/profuzzbench -it pingu-eval python3 scripts/evaluation/summary.py "${coverage_files[@]}"
else 
    docker exec -w /home/user/profuzzbench -it pingu-eval python3 scripts/evaluation/plot.py -c 60 -s 1 -o "${output_tar_prefix}-coverage.png" "${coverage_files[@]}"
fi