#!/usr/bin/env bash

USER_SUFFIX="$(id -u -n)"

text_red=$(tput setaf 1)   # Red
text_green=$(tput setaf 2) # Green
text_bold=$(tput bold)     # Bold
text_reset=$(tput sgr0)    # Reset your text

function log_error {
  echo "${text_bold}${text_red}${1}${text_reset}"
}

function log_success {
  echo "${text_bold}${text_green}${1}${text_reset}"
}

function log_info {
  echo "${text_bold}${text_green}${1}${text_reset}"
}

function use_prebuilt {
  if [[ ! -z "${!PREBUILT_ENV_VAR_NAME:-}" ]]; then
    return 0
  fi
  return 1
}

function check_aslr_disabled {
    local aslr_value=$(cat /proc/sys/kernel/randomize_va_space)
    if [ "$aslr_value" != "0" ]; then
        log_error "ASLR is enabled (value: $aslr_value). Please disable it by running:"
        log_error "    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space"
        exit 1
    fi
}

function get_args_after_double_dash {
    local args=()

    # 跳过 -- 之前的参数
    while [[ "$1" != "--" ]]; do
        if [[ -z $1 ]]; then
            echo ""
            return
        fi
        shift
    done

    # 跳过 -- 本身
    shift

    # 收集所有剩余参数，保持原始形式
    while [[ -n "$1" ]]; do
        # 保留每个参数的原始形式，包括 -e 标志
        args+=("$1")
        shift
    done

    # 使用引号打印所有参数，保持完整的参数结构
    printf '%s ' "${args[@]}"
}

function get_args_before_double_dash() {
  # 初始化一个空数组来存储参数
  local args=()

  # 遍历所有参数
  while [[ $# -gt 0 ]]; do
    if [[ $1 == "--" ]]; then
      # 遇到 -- 时，停止遍历
      break
    fi
    if [[ -z $1 ]]; then
      echo ""
      return
    fi
    # 将参数添加到数组中
    args+=("$1")
    # 移动到下一个参数
    shift
  done

  # 打印参数列表
  echo -n "${args[@]}"
}

function compute_coverage {
  replayer=$1
  testcases=$(eval "$2")
  step=$3
  covfile=$4
  cov_cmd=$5

  # delete the existing coverage file
  rm $covfile || true
  touch $covfile

  # output the header of the coverage file which is in the CSV format
  # Time: timestamp, l_per/b_per and l_abs/b_abs: line/branch coverage in percentage and absolutate number
  echo "time,l_abs,l_per,b_abs,b_per"
  echo "time,l_abs,l_per,b_abs,b_per" >>$covfile

  # process other testcases
  count=0
  for f in $testcases; do
    echo $f
    time=$(stat -c %Y $f)
    "$replayer" "$f" || true

    count=$((count + 1))
    rem=$((count % step))
    if [ "$rem" != "0" ]; then continue; fi
    # Run the coverage command if provided, otherwise use default gcovr command
    if [ -n "$cov_cmd" ]; then
        cov_data=$(eval "$cov_cmd")
    else
        cov_data=$(gcovr -r . -s | grep "[lb][a-z]*:")
    fi
    l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
    l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
    b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
    b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
    echo "$time,$l_abs,$l_per,$b_abs,$b_per"
    echo "$time,$l_abs,$l_per,$b_abs,$b_per" >>$covfile
  done

  # output cov data for the last testcase(s) if step > 1
  if [[ $step -gt 1 ]]; then
    time=$(stat -c %Y $f)
    # Run the coverage command if provided, otherwise use default gcovr command
    if [ -n "$cov_cmd" ]; then
        cov_data=$(eval "$cov_cmd")
    else
        cov_data=$(gcovr -r . -s | grep "[lb][a-z]*:")
    fi
    l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
    l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
    b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
    b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
    echo "$time,$l_abs,$l_per,$b_abs,$b_per"
    echo "$time,$l_abs,$l_per,$b_abs,$b_per" >>$covfile
  fi
}

sleep_ms_perl() {
    local ms=$1
    perl -e "select(undef, undef, undef, $ms/1000)"
}

check_port_listening() {
    local port="$1"
    local timeout="${2:-3}"  # default timeout is 3s
    local interval="${3:-1}"  # default check interval is 1ms

    local start_time=$(date +%s)

    while true; do
        if command -v ss &> /dev/null; then
            if ss -tln | grep -q ":$port "; then
                echo "Port $port is now listening"
                return 0
            fi
        elif command -v netstat &> /dev/null; then
            if netstat -tln | grep -q ":$port "; then
                echo "Port $port is now listening"
                return 0
            fi
        else
            echo "Error: Neither 'ss' nor 'netstat' command found" >&2
            return 2
        fi

        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -ge $timeout ]; then
            echo "Timeout reached. Port $port is not listening" >&2
            return 1
        fi

        sleep_ms_perl $interval
    done
}
