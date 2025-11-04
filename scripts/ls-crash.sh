#!/bin/bash
# -*- coding: utf-8 -*-
#
# 崩溃目录统计脚本
# 遍历指定目录下的所有文件夹，查找 asan、crashing、replayable-crashes 目录
# 并统计各目录中的文件数量
#

# 注意: 不使用 set -e，因为某些目录可能会有权限问题或其他错误
# 我们希望即使某个目录扫描失败，也能继续扫描其他目录
set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 扫描的目录名称列表
MONITOR_DIRS=("asan" "crashing" "replayable-crashes" "replayable-hangs")

# 显示使用帮助
usage() {
    cat << EOF
用法: $0 [选项] <目录路径>

统计指定目录下所有文件夹中的崩溃文件目录（asan、crashing、replayable-crashes）
并显示各目录包含的文件数量。

选项:
    -h, --help          显示此帮助信息
    -s, --summary       只显示汇总统计
    -v, --verbose       显示详细信息（包括空目录）
    -f, --files         同时列出文件名

示例:
    $0 output                    # 统计 output 目录
    $0 -s output                 # 只显示汇总
    $0 -v output                 # 显示详细信息包括空目录
    $0 -f output                 # 同时列出文件名

EOF
    exit 0
}

# 计算目录中的文件数量（递归）
count_files() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo 0
        return
    fi
    # 使用 find 递归统计文件数量（不包括目录）
    # 添加错误处理，忽略权限错误
    local count=$(find "$dir" -type f 2>/dev/null | wc -l)
    echo "$count"
}

# 列出目录中的文件
list_files() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        return
    fi
    # 添加错误处理，忽略权限错误
    # 使用兼容的方式代替 -printf
    find "$dir" -type f 2>/dev/null | while read -r file; do
        local rel_path="${file#$dir/}"
        echo "        - $rel_path"
    done | sort
}

# 主函数
main() {
    local target_dir=""
    local summary_only=0
    local verbose=0
    local show_files=0
    
    # 解析命令行参数
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -s|--summary)
                summary_only=1
                shift
                ;;
            -v|--verbose)
                verbose=1
                shift
                ;;
            -f|--files)
                show_files=1
                shift
                ;;
            -*)
                echo -e "${RED}错误: 未知选项 '$1'${NC}" >&2
                echo "使用 '$0 --help' 查看帮助信息" >&2
                exit 1
                ;;
            *)
                target_dir="$1"
                shift
                ;;
        esac
    done
    
    # 检查是否提供了目录参数
    if [[ -z "$target_dir" ]]; then
        echo -e "${RED}错误: 请指定要扫描的目录${NC}" >&2
        echo "使用 '$0 --help' 查看帮助信息" >&2
        exit 1
    fi
    
    # 检查目录是否存在
    if [[ ! -d "$target_dir" ]]; then
        echo -e "${RED}错误: 目录不存在: $target_dir${NC}" >&2
        exit 1
    fi
    
    # 转换为绝对路径
    if command -v realpath &> /dev/null; then
        target_dir=$(realpath "$target_dir")
    else
        # 如果 realpath 不可用，使用 cd + pwd
        target_dir=$(cd "$target_dir" && pwd)
    fi
    
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}崩溃目录统计${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo -e "扫描目录: ${BLUE}$target_dir${NC}"
    echo -e "扫描类型: ${YELLOW}${MONITOR_DIRS[*]}${NC}"
    echo ""
    
    # 统计变量
    local total_dirs=0
    local total_files=0
    declare -A type_counts  # 各类型的目录数量
    declare -A type_files   # 各类型的文件数量
    
    # 初始化统计
    for dir_name in "${MONITOR_DIRS[@]}"; do
        type_counts["$dir_name"]=0
        type_files["$dir_name"]=0
    done
    
    # 遍历目标目录下的所有直接子目录（不递归）
    for campaign in "$target_dir"/*; do
        if [[ ! -d "$campaign" ]]; then
            continue
        fi
        
        local campaign_name=$(basename "$campaign")
        local found_any=0
        
        # 检查每种扫描目录类型
        for dir_name in "${MONITOR_DIRS[@]}"; do
            local poc_dir="$campaign/$dir_name"
            
            if [[ -d "$poc_dir" ]]; then
                # 使用错误处理确保即使 count_files 失败也能继续
                local file_count=$(count_files "$poc_dir") || file_count=0
                
                # 如果不是详细模式且文件数为0，跳过显示
                if [[ $verbose -eq 0 && $file_count -eq 0 ]]; then
                    continue
                fi
                
                # 如果是仅汇总模式，只累计统计
                if [[ $summary_only -eq 0 ]]; then
                    if [[ $found_any -eq 0 ]]; then
                        echo -e "${GREEN}📁 $campaign_name${NC}"
                        found_any=1
                    fi
                    
                    # 显示目录和文件数量
                    if [[ $file_count -eq 0 ]]; then
                        echo -e "    ${YELLOW}[$dir_name]${NC} $poc_dir ${RED}(空)${NC}"
                    else
                        echo -e "    ${YELLOW}[$dir_name]${NC} $poc_dir ${GREEN}(${file_count} 个文件)${NC}"
                    fi
                    
                    # 如果需要列出文件（添加错误处理）
                    if [[ $show_files -eq 1 && $file_count -gt 0 ]]; then
                        list_files "$poc_dir" || echo "        ${RED}(无法列出文件)${NC}"
                    fi
                fi
                
                # 累计统计（确保算术运算不会失败）
                type_counts["$dir_name"]=$((${type_counts["$dir_name"]} + 1))
                type_files["$dir_name"]=$((${type_files["$dir_name"]} + file_count))
                total_dirs=$((total_dirs + 1))
                total_files=$((total_files + file_count))
            fi
        done
        
        # 在非汇总模式下，如果找到了目录，添加空行分隔
        if [[ $summary_only -eq 0 && $found_any -eq 1 ]]; then
            echo ""
        fi
    done
    
    # 显示汇总统计
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}📊 汇总统计${NC}"
    echo -e "${CYAN}========================================${NC}"
    
    for dir_name in "${MONITOR_DIRS[@]}"; do
        local dir_count=${type_counts["$dir_name"]}
        local file_count=${type_files["$dir_name"]}
        
        if [[ $dir_count -gt 0 || $verbose -eq 1 ]]; then
            printf "%-20s: " "$dir_name"
            if [[ $dir_count -eq 0 ]]; then
                echo -e "${RED}未找到${NC}"
            else
                echo -e "${GREEN}${dir_count} 个目录${NC}, ${YELLOW}${file_count} 个文件${NC}"
            fi
        fi
    done
    
    echo ""
    echo -e "总计: ${GREEN}${total_dirs}${NC} 个扫描目录, ${YELLOW}${total_files}${NC} 个文件"
    echo ""
}

# 执行主函数
main "$@"

