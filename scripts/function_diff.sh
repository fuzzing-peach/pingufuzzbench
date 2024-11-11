#!/bin/bash

function extract_function() {
    local file=$1
    local func=$2
    sed -n "/^$func[[:space:]]*()[[:space:]]*{/,/^}/p" "$file"
}

if [ $# -ne 3 ]; then
    echo "Usage: $0 <function_name> <file1> <file2>" >&2
    exit 2
fi

func_name=$1
file1=$2
file2=$3

extract_function "$file1" "$func_name" > /tmp/func1
extract_function "$file2" "$func_name" > /tmp/func2

# 使用 diff 比较函数，但不输出差异
diff -q /tmp/func1 /tmp/func2 > /dev/null

# 保存 diff 的退出状态
diff_exit_status=$?

# 清理临时文件
rm /tmp/func1 /tmp/func2

# 返回 diff 的退出状态
exit $diff_exit_status