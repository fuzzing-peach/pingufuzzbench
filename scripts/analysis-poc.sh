#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "用法: $0 [-o <output父目录>] <容器名称>" >&2
    exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
output_parent_dir="${repo_root}/output"

while getopts ":o:h" opt; do
    case "${opt}" in
        o)
            if ! output_parent_dir="$(realpath "${OPTARG}")"; then
                echo "无法解析输出父目录: ${OPTARG}" >&2
                exit 1
            fi
            ;;
        h)
            usage
            ;;
        \?)
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

[[ $# -eq 1 ]] || usage

container_name="$1"
output_dir="${output_parent_dir%/}/${container_name}"

if [[ ! -d "${output_dir}" ]]; then
    echo "输出目录不存在: ${output_dir}" >&2
    exit 1
fi

if ! docker inspect "${container_name}" >/dev/null 2>&1; then
    echo "找不到容器 ${container_name}，无法获得镜像名称。" >&2
    exit 1
fi

image_name="$(docker inspect --format '{{.Config.Image}}' "${container_name}")"

if [[ -z "${image_name}" ]]; then
    echo "无法从容器 ${container_name} 获取镜像名称。" >&2
    exit 1
fi

analysis_container_name="${container_name}-analysis-poc"
if docker ps --format '{{.Names}}' | grep -Fxq "${analysis_container_name}"; then
    echo "容器 ${analysis_container_name} 已在运行，进入现有容器..." >&2
    docker exec -it "${analysis_container_name}" /bin/bash
    exit 0
elif docker ps -a --format '{{.Names}}' | grep -Fxq "${analysis_container_name}"; then
    echo "容器 ${analysis_container_name} 已存在但未运行，正在启动..." >&2
    docker start "${analysis_container_name}"
    docker exec -it "${analysis_container_name}" /bin/bash
    exit 0
fi

docker run -it --rm \
    --cap-add=SYS_ADMIN \
    --cap-add=SYS_RAWIO \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    --sysctl net.ipv4.tcp_tw_reuse=1 \
    --user $(id -u):$(id -g) \
    -v /etc/localtime:/etc/localtime:ro \
    -v /etc/timezone:/etc/timezone:ro \
    -v "${repo_root}:/home/user/profuzzbench" \
    -v "${output_dir}:/tmp/fuzzing-output:rw" \
    --mount type=tmpfs,destination=/tmp,tmpfs-mode=777 \
    --ulimit msgqueue=2097152000 \
    --name "${analysis_container_name}" \
    "${image_name}" \
    /bin/bash

exit 0