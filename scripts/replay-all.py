#!/usr/bin/env python3
"""
递归遍历输入目录，对每个非文本文件执行重放测试。
先启动服务器进程，再启动重放器进程，并打印服务器进程的 stderr。
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path


# 常见文本文件后缀（从 utils.sh 中提取）
TEXT_EXTENSIONS = {
    'txt', 'log', 'md', 'csv', 'json', 'xml', 'yml', 'yaml',
    'ini', 'conf', 'cfg', 'html', 'htm', 'py', 'sh',
    'c', 'cpp', 'h', 'hpp', 'java', 'rb', 'js', 'ts'
}


def is_text_file(filepath):
    """检查文件是否为文本文件（根据后缀名）"""
    ext = Path(filepath).suffix.lstrip('.').lower()
    return ext in TEXT_EXTENSIONS


def find_files(input_dir):
    """递归遍历目录，返回所有非文本文件"""
    files = []
    for root, dirs, filenames in os.walk(input_dir):
        for filename in filenames:
            filepath = os.path.join(root, filename)
            if not is_text_file(filepath):
                files.append(filepath)
    return files


def run_replay(server_cmd, replayer_cmd, input_file, clear_cmd=None):
    """运行一次重放测试"""
    # 执行清理命令（如果提供）
    if clear_cmd:
        clear_args = clear_cmd.split()
        try:
            subprocess.run(clear_args, check=False, capture_output=True)
        except Exception as e:
            print(f"警告: 清理命令执行失败: {e}", file=sys.stderr)
    
    # 替换 replayer_cmd 中的 @@ 为实际文件路径
    replayer_args = replayer_cmd.replace('@@', input_file).split()
    
    # 解析 server_cmd
    server_args = server_cmd.split()

    print(f"服务器命令: {' '.join(server_args)}")
    print(f"重放器命令: {' '.join(replayer_args)}")
    
    # 启动服务器进程（继承环境变量）
    server_process = subprocess.Popen(
        server_args,
        stderr=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        env=os.environ.copy()  # 显式继承当前环境变量
    )
    
    try:
        # 等待服务器启动（可以添加短暂延迟）
        import time
        time.sleep(1)
        
        # 启动重放器进程
        replayer_process = subprocess.Popen(
            replayer_args,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
        # 等待重放器最多3秒，之后强制杀死
        try:
            replayer_stdout, replayer_stderr = replayer_process.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            replayer_process.kill()
            replayer_stdout, replayer_stderr = replayer_process.communicate()
        replayer_returncode = replayer_process.returncode
        
        # 先终止服务器进程，再读取其 stderr
        if server_process.poll() is not None:
            # 服务器已经退出，立刻退出该函数
            print(f"Server process exited accidentally !!!!!!")
        
        server_process.terminate()
        try:
            server_process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            server_process.kill()
        
        _, stderr_data = server_process.communicate()

        if stderr_data:
            # 解码并打印，使用 replace 策略防止二进制乱码导致脚本崩溃
            err_text = stderr_data.decode('utf-8', errors='replace').strip()
            # if err_text:
            #     print("-" * 20 + " Server Stderr " + "-" * 20)
            #     print(err_text)
            #     print("-" * 55)
        
    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        # 确保清理服务器进程
        if server_process.poll() is None:
            server_process.terminate()
            try:
                server_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                server_process.kill()
                server_process.wait()
        return 1


def main():
    parser = argparse.ArgumentParser(
        description='递归遍历输入目录，对每个非文本文件执行重放测试'
    )
    parser.add_argument('server_cmd', help='服务器启动命令')
    parser.add_argument('replayer_cmd', help='重放器命令（使用 @@ 作为文件路径占位符）')
    parser.add_argument('input_dir', help='输入目录路径')
    parser.add_argument('--clear-cmd', dest='clear_cmd', default=None,
                        help='每次重放前执行的清理命令（可选）')
    
    args = parser.parse_args()
    
    # 检查输入目录是否存在
    if not os.path.isdir(args.input_dir):
        print(f"错误: 输入目录不存在: {args.input_dir}", file=sys.stderr)
        sys.exit(1)
    
    # 查找所有非文本文件
    files = find_files(args.input_dir)
    
    if not files:
        print(f"警告: 在 {args.input_dir} 中未找到任何非文本文件", file=sys.stderr)
        return
    
    print(f"找到 {len(files)} 个文件需要处理")
    
    # 处理每个文件
    for filepath in files:
        returncode = run_replay(args.server_cmd, args.replayer_cmd, filepath, args.clear_cmd)
        if returncode != 0:
            print(f"警告: 重放器返回非零退出码: {returncode}")


if __name__ == '__main__':
    main()

