#!/usr/bin/env bash

set -e
set -o pipefail
cd $(dirname $0)
cd ..
source scripts/utils.sh

# Check if kernel.core_pattern is set to 'core'
# core_pattern=$(cat /proc/sys/kernel/core_pattern)
# if [ "$core_pattern" != "core" ]; then
#     log_error "[!] kernel.core_pattern is not set to 'core'. Current value: $core_pattern"
#     log_error "[!] Please set it to 'core' using: echo core | sudo tee /proc/sys/kernel/core_pattern"
#     exit 1
# fi

# log_success "[+] kernel.core_pattern is correctly set to 'core'"

# Parameters after -- is passed directly to the run script
args=($(get_args_before_double_dash "$@"))
fuzzer_args=$(get_args_after_double_dash "$@")

opt_args=$(getopt -o o:f:t:v: -l output:,fuzzer:,generator:,target:,version:,times:,timeout:,cleanup,detached,dry-run,replay-step:,gcov-step:,cpu-affinity:,no-cpu -- "${args[@]}")
if [ $? != 0 ]; then
    log_error "[!] Error in parsing shell arguments."
    exit 1
fi

eval set -- "${opt_args}"
while true; do
    case "$1" in
    -o | --output)
        output="$2"
        shift 2
        ;;
    -f | --fuzzer)
        fuzzer="$2"
        shift 2
        ;;
    --generator)
        generator="$2"
        shift 2
        ;;
    -t | --target)
        target="$2"
        shift 2
        ;;
    -v | --version)
        version="$2"
        shift 2
        ;;
    --times)
        times="$2"
        shift 2
        ;;
    --timeout)
        timeout="$2"
        shift 2
        ;;
    --cleanup)
        cleanup=1
        shift 1
        ;;
    --detached)
        detached=1
        shift 1
        ;;
    --dry-run)
        dry_run=1
        shift 1
        ;;
    --replay-step)
        replay_step="$2"
        shift 2
        ;;
    --gcov-step)
        gcov_step="$2"
        shift 2
        ;;
    --cpu-affinity)
        if [[ -n "$no_cpu_affinity" ]]; then
            log_error "[!] --cpu-affinity and --no-cpu cannot be used together"
            exit 1
        fi
        cpu_affinity="$2"
        shift 2
        ;;
    --no-cpu)
        if [[ -n "$cpu_affinity" ]]; then
            log_error "[!] --cpu-affinity and --no-cpu cannot be used together"
            exit 1
        fi
        no_cpu_affinity=1
        shift 1
        ;;
    *)
        # echo "Usage: run.sh -t TARGET -f FUZZER -v VERSION [--times TIMES, --timeout TIMEOUT]"
        break
        ;;
    esac
done

if [[ -n "$generator" && "$fuzzer" != "ft" && "$fuzzer" != "pingu" ]]; then
    log_error "[!] Argument --generator is only allowed when --fuzzer is ft or pingu"
    exit 1
fi

if [[ -z "$version" ]]; then
    log_error "[!] --version is required"
    exit 1
fi

times=${times:-"1"}
replay_step=${replay_step:-"1"}
gcov_step=${gcov_step:-"1"}
protocol=${target%/*}
impl=${target##*/}
# image_name=$(echo "pingu-$fuzzer-$protocol-$impl:$impl_version" | tr 'A-Z' 'a-z')
if [[ -z "$generator" ]]; then
    image_name=$(echo "pingu-${fuzzer}-${protocol}-${impl}:${version:-latest}" | tr 'A-Z' 'a-z')
    container_name="pingu-${fuzzer}-${protocol}-${impl}"
else
    image_name=$(echo "pingu-${fuzzer}-${generator}-${protocol}-${impl}:${version:-latest}" | tr 'A-Z' 'a-z')
    container_name="pingu-${fuzzer}-${generator}-${protocol}-${impl}"
fi

image_id=$(docker images -q "$image_name")
if [[ -n "$image_id" ]]; then
    log_success "[+] Using docker image: $image_name"
else
    log_error "[!] Docker image not found: $image_name"
    exit 1
fi

output=$(realpath "$output")

# If .env exists at repo root, forward its variables to `docker run` via `-e`.
# Supports lines like `KEY=VALUE` or `export KEY=VALUE`; ignores blanks/comments.
dotenv_env_args=""
if [[ -f ".env" ]]; then
    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        # trim leading/trailing whitespace
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

        line="${line#export }"
        if [[ "$line" =~ ^([^=[:space:]]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            # trim value and strip simple surrounding quotes
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            if [[ "$value" =~ ^\".*\"$ ]] || [[ "$value" =~ ^\'.*\'$ ]]; then
                value="${value:1:${#value}-2}"
            fi

            # Guard against malformed .env lines that accidentally contain another assignment.
            if [[ "$value" =~ [A-Za-z_][A-Za-z0-9_]*= ]]; then
                log_error "[!] Skip malformed .env entry: ${key}=... (contains nested KEY=VALUE)"
                continue
            fi

            escaped_kv=$(printf '%q' "${key}=${value}")
            dotenv_env_args+=" -e ${escaped_kv}"
        fi
    done < .env
fi

cores_per_container=1
case "$fuzzer" in
    ft | ft-net | pingu)
        cores_per_container=4
        ;;
    aflnet | stateafl | sgfuzz)
        cores_per_container=4
        ;;
esac

declare -a idle_cores_array
if [[ -z "$no_cpu_affinity" && -z "$cpu_affinity" ]]; then
    idle_cores=$(python3 ./scripts/idle_cpu.py "$times" "$cores_per_container" "$output")
    idle_cores_array=($idle_cores)
fi

log_success "[+] Ready to launch image: $image_id"
cids=()
for i in $(seq 1 $times); do
    # use current ms timestamp as the id
    ts=$(date +%s%3N)
    cpuset_cpus=""
    if [[ -n "$no_cpu_affinity" ]]; then
        idle_core="x"
        attached_core="none"
    elif [[ -n "$cpu_affinity" ]]; then
        if [[ "$cpu_affinity" =~ ^[0-9]+$ ]]; then
            start_core=$((cpu_affinity + (i - 1) * cores_per_container))
            end_core=$((start_core + cores_per_container - 1))
            cpuset_cpus="${start_core}-${end_core}"
        elif [[ "$cpu_affinity" =~ ^[0-9]+(,[0-9]+)*$ ]] && [[ "$times" -gt 1 ]]; then
            IFS=',' read -r -a manual_starts <<< "$cpu_affinity"
            if [[ "${#manual_starts[@]}" -ne "$times" ]]; then
                log_error "[!] --cpu-affinity as start-core list requires exactly --times values"
                exit 1
            fi
            start_core="${manual_starts[$((i-1))]}"
            end_core=$((start_core + cores_per_container - 1))
            cpuset_cpus="${start_core}-${end_core}"
        else
            cpuset_cpus="$cpu_affinity"
        fi

        idle_core=$(echo "$cpuset_cpus" | awk -F'[-,]' '{print $1}')
        attached_core="$cpuset_cpus"
    else
        idle_core=${idle_cores_array[$((i-1))]}
        end_core=$((idle_core + cores_per_container - 1))
        cpuset_cpus="${idle_core}-${end_core}"
        attached_core="$cpuset_cpus"
    fi
    # 将 CPU ID 加入到容器名称中: name-index-cpuid-timestamp
    cname="${container_name}-${i}-cpu${idle_core}-${ts}"
    if [[ -z "$dry_run" ]]; then
        mkdir -p "${output}/${cname}"
    fi

    #         # -e PFB_CPU_CORE=${idle_core} \

    container_fuzzing_args="${fuzzer_args}"
    afl_env_args=""
    case "$fuzzer" in
        aflnet | stateafl)
            # CPU pinning is handled by Docker cpuset; disable AFL internal binding.
            afl_env_args="-e AFL_NO_AFFINITY=1"
            ;;
    esac
    cmd="docker run -it -d --privileged \
        --cap-add=SYS_ADMIN --cap-add=SYS_RAWIO --cap-add=SYS_PTRACE \
        --security-opt seccomp=unconfined \
        --security-opt apparmor=unconfined \
        --sysctl net.ipv4.tcp_tw_reuse=1 \
        --sysctl fs.mqueue.msgsize_max=65536 \
        --sysctl fs.mqueue.msg_max=1024 \
        --sysctl fs.mqueue.queues_max=1024 \
        ${afl_env_args} \
        ${dotenv_env_args} \
        --user $(id -u):$(id -g) \
        -v /etc/localtime:/etc/localtime:ro \
        -v /etc/timezone:/etc/timezone:ro \
        -v $(pwd):/home/user/profuzzbench \
        -v ${output}/${cname}:/tmp/fuzzing-output:rw \
        --mount type=tmpfs,destination=/tmp,tmpfs-mode=777 \
        --ulimit msgqueue=2097152000 \
        --shm-size=64G \
        --name $cname \
        ${cpuset_cpus:+--cpuset-cpus $cpuset_cpus} \
        $image_name \
        /bin/bash -c \"bash /home/user/profuzzbench/scripts/dispatch.sh $target run $fuzzer $replay_step $gcov_step $timeout ${container_fuzzing_args} > /tmp/fuzzing-output/stdout.log 2> /tmp/fuzzing-output/stderr.log\""
    echo $cmd
    if [[ -n "$dry_run" ]]; then
        continue
    fi
    id=$(eval $cmd)
    echo "$attached_core" >> ${output}/${cname}/attached_core
    log_success "[+] Launch docker container: ${cname}"
    cids+=(${id::12}) # store only the first 12 characters of a container ID
    sleep 1
done

if [[ -n "$dry_run" ]]; then
    exit 0
fi

dlist="" # docker list
for id in ${cids[@]}; do
    dlist+=" ${id}"
done

# wait until all these dockers are stopped
log_success "[+] Fuzzing in progress ..."
log_success "[+] Waiting for the following containers to stop: ${dlist}"

function maybe_cleanup() {
    local index=1
    for id in ${cids[@]}; do
        if [ ! -z "$cleanup" ]; then
            docker rm ${id} >/dev/null
            log_success "[+] Container $id deleted"
        fi
        index=$((index+1))
    done
}

if [ ! -z "$detached" ]; then
    (
        docker wait $dlist >/dev/null
        maybe_cleanup
    ) &
    pid=$!
    log_success "[+] Background process spawned with PID: $pid"
    disown $pid
else
    docker wait $dlist >/dev/null
    maybe_cleanup
fi
