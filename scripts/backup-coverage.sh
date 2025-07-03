#!/bin/bash

# 用法：脚本默认从当前目录搜索，也可指定目录，例如：
# ./copy_coverage.sh /path/to/search

SOURCE_DIR="${1:-.}"  # 源目录（参数或默认当前目录）
DEST_DIR="${2:-.}"     # 目标目录（脚本所在路径）

# 查找所有直接子目录中的 coverage.csv 文件
find "$SOURCE_DIR" -maxdepth 2 -mindepth 2 -type f -name "coverage.csv" -print0 | while IFS= read -r -d '' file; do
    # 获取子目录名称（直接父目录名）
    parent_dir=$(dirname "$file")
    dir_name=$(basename "$parent_dir")

    # 构建目标路径
    dest_file="${DEST_DIR}/${dir_name}.csv"

    # 复制并重命名文件
    echo "backup: $file => $dest_file"
    cp -f "$file" "$dest_file"
done

echo "backup done! *.csv files are in $DEST_DIR"