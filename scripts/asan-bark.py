#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
崩溃文件监控脚本
监控当前目录下所有文件夹中的 asan、crashing、replayable-crashes 等子目录
检测新文件并发送 HTTP 通知
"""

import os
import sys
import json
import time
import argparse
import requests
from pathlib import Path
from datetime import datetime
from typing import Set, Dict
from urllib.parse import quote

# ==================== 配置区 ====================
# HTTP 通知配置
WEBHOOK_URL = os.environ.get("BARK_WEBHOOK_URL")  # 从环境变量读取 webhook 地址
if not WEBHOOK_URL:
    print("❌ 错误: 未设置 BARK_WEBHOOK_URL 环境变量")
    sys.exit(1)
    
HTTP_METHOD = "GET"  # GET 或 POST
HTTP_TIMEOUT = 10  # 请求超时时间（秒）

# 监控配置
CHECK_INTERVAL = 30  # 检查间隔（秒）
STATE_FILE = "asan_monitor_state.json"  # 状态文件名
LOG_FILE = "asan_monitor.log"  # 日志文件名
MONITOR_DIRS = ["asan", "crashing", "replayable-crashes", "crashes"]  # 需要监控的目录名称列表
IGNORED_DIRS = {"replayable-hangs"}  # 显式忽略的目录名称

# ================================================


class AsanMonitor:
    """崩溃文件监控器 - 监控 asan、crashing、replayable-crashes 等目录"""
    
    def __init__(self, base_dir: str = ".", check_interval: int = CHECK_INTERVAL):
        self.base_dir = Path(base_dir).resolve()
        self.state_file = self.base_dir / STATE_FILE
        self.log_file = self.base_dir / LOG_FILE
        self.check_interval = check_interval
        self.known_files: Dict[str, Set[str]] = {}
        self.load_state()
    
    def log(self, message: str):
        """记录日志"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        log_message = f"[{timestamp}] {message}"
        print(log_message)
        
        # 追加到日志文件
        try:
            with open(self.log_file, "a", encoding="utf-8") as f:
                f.write(log_message + "\n")
        except Exception as e:
            print(f"写入日志文件失败: {e}")
    
    def load_state(self):
        """从文件加载已知文件状态"""
        if self.state_file.exists():
            try:
                with open(self.state_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    # 将列表转换为集合
                    self.known_files = {k: set(v) for k, v in data.items()}
                self.log(f"加载状态文件成功，监控 {len(self.known_files)} 个目录")
            except Exception as e:
                self.log(f"加载状态文件失败: {e}，将创建新状态")
                self.known_files = {}
        else:
            self.log("状态文件不存在，初始化监控状态")
            self.known_files = {}
    
    def save_state(self):
        """保存当前文件状态到文件"""
        try:
            # 将集合转换为列表以便 JSON 序列化
            data = {k: list(v) for k, v in self.known_files.items()}
            with open(self.state_file, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
        except Exception as e:
            self.log(f"保存状态文件失败: {e}")
    
    def scan_monitored_directories(self) -> Dict[str, Set[str]]:
        """扫描所有需要监控的目录（asan、crashing、replayable-crashes），返回当前文件状态"""
        current_state = {}
        
        # 遍历当前目录下的所有子目录
        try:
            for item in self.base_dir.iterdir():
                if not item.is_dir():
                    continue
                
                # 检查是否有需要监控的子目录
                for monitor_dir_name in MONITOR_DIRS:
                    if monitor_dir_name in IGNORED_DIRS:
                        continue
                    target_dir = item / monitor_dir_name
                    if target_dir.exists() and target_dir.is_dir():
                        # 获取该目录下的所有文件
                        try:
                            files = set()
                            for file_path in target_dir.rglob("*"):
                                if file_path.is_file():
                                    if any(part in IGNORED_DIRS for part in file_path.parts):
                                        continue
                                    # 保存相对于目标目录的路径
                                    rel_path = file_path.relative_to(target_dir)
                                    files.add(str(rel_path))
                            
                            target_path_str = str(target_dir.relative_to(self.base_dir))
                            current_state[target_path_str] = files
                        except Exception as e:
                            self.log(f"扫描 {target_dir} 失败: {e}")
        except Exception as e:
            self.log(f"扫描目录失败: {e}")
        
        return current_state
    
    def send_notification(self, new_files: Dict[str, Set[str]], new_directories: list = None):
        """发送 HTTP 通知"""
        # 构建消息内容
        message_parts = []
        
        # 如果有新目录，先报告
        if new_directories:
            message_parts.append(f"🆕 发现 {len(new_directories)} 个新的监控目录")
            for new_dir in new_directories:
                message_parts.append(f"  - {new_dir}")
            message_parts.append("")
        
        message_parts.append("⚠️ 检测到新文件:")
        total_count = 0
        
        for target_dir, files in new_files.items():
            message_parts.append(f"\n目录: {target_dir}")
            message_parts.append(f"  新增文件数: {len(files)}")
            for file in sorted(files):
                message_parts.append(f"    - {file}")
            total_count += len(files)
        
        message = "\n".join(message_parts)
        self.log(message)

        encoded_message = quote(message, safe='')
        url = WEBHOOK_URL + f"检测到崩溃文件/{encoded_message}?level=passive"
        try:
            print(f"✉️ 发送 HTTP 请求: {url}")
            response = requests.get(
                url,
                timeout=HTTP_TIMEOUT
            )
            
            if response.status_code == 200:
                self.log(f"HTTP 通知发送成功 (状态码: {response.status_code})")
            else:
                self.log(f"HTTP 通知返回异常状态码: {response.status_code}")
        except requests.exceptions.Timeout:
            self.log(f"HTTP 请求超时 (超时设置: {HTTP_TIMEOUT}秒)")
        except requests.exceptions.RequestException as e:
            self.log(f"HTTP 请求失败: {e}")
        except Exception as e:
            self.log(f"发送通知时发生未知错误: {e}")
    
    def check_for_new_files(self):
        """检查是否有新文件和新目录"""
        current_state = self.scan_monitored_directories()
        new_files = {}
        new_directories = []
        
        # 检查是否有新的监控目录出现
        for target_dir in current_state.keys():
            if target_dir not in self.known_files:
                new_directories.append(target_dir)
                self.log(f"🆕 动态发现新的监控目录: {target_dir}")
        
        # 检查每个监控目录中的文件
        for target_dir, current_files in current_state.items():
            if target_dir in self.known_files:
                # 找出新增的文件
                new = current_files - self.known_files[target_dir]
                if new:
                    new_files[target_dir] = new
                    self.log(f"📄 {target_dir} 发现 {len(new)} 个新文件")
            else:
                # 新的监控目录
                if current_files:
                    self.log(f"   └─ 包含 {len(current_files)} 个文件")
                    new_files[target_dir] = current_files
        
        # 检查是否有监控目录消失（仅记录，不影响状态）
        disappeared_dirs = set(self.known_files.keys()) - set(current_state.keys())
        if disappeared_dirs:
            for disappeared_dir in disappeared_dirs:
                self.log(f"⚠️  监控目录已消失: {disappeared_dir}")
        
        # 更新已知状态
        self.known_files = current_state
        self.save_state()
        
        # 如果有新文件，发送通知
        if new_files:
            self.send_notification(new_files, new_directories)
            return True
        
        return False
    
    def run(self):
        """运行监控循环"""
        self.log("=" * 60)
        self.log("崩溃文件监控器启动")
        self.log(f"监控根目录: {self.base_dir}")
        self.log(f"监控目录类型: {', '.join(MONITOR_DIRS)}")
        self.log(f"Webhook URL: {WEBHOOK_URL}")
        self.log(f"检查间隔: {self.check_interval} 秒")
        self.log("=" * 60)
        
        # 首次扫描，仅记录当前状态，不发送通知
        self.log("执行初始扫描...")
        initial_state = self.scan_monitored_directories()
        if not self.known_files:
            self.known_files = initial_state
            self.save_state()
            self.log(f"初始化完成，找到 {len(self.known_files)} 个监控目录")
            for target_dir, files in self.known_files.items():
                self.log(f"  {target_dir}: {len(files)} 个文件")
        
        # 开始监控循环
        try:
            while True:
                time.sleep(self.check_interval)
                self.log(f"执行检查... (间隔: {self.check_interval}秒)")
                self.check_for_new_files()
        except KeyboardInterrupt:
            self.log("收到中断信号，停止监控")
        except Exception as e:
            self.log(f"监控循环发生错误: {e}")
            raise


def main():
    """主函数"""
    # 解析命令行参数
    parser = argparse.ArgumentParser(
        description="崩溃文件监控脚本 - 监控 asan、crashing、replayable-crashes 等目录",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例用法:
  %(prog)s                          # 监控脚本所在目录
  %(prog)s -o /path/to/output       # 监控指定的 output 目录
  %(prog)s --output ./output        # 使用相对路径
  %(prog)s -i 60                    # 设置检查间隔为 60 秒
        """
    )
    
    parser.add_argument(
        '-o', '--output',
        type=str,
        default=None,
        help='指定要监控的目录路径（默认为脚本所在目录）'
    )
    
    parser.add_argument(
        '-i', '--interval',
        type=int,
        default=None,
        help=f'检查间隔（秒），默认为 {CHECK_INTERVAL} 秒'
    )
    
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='显示详细输出'
    )
    
    args = parser.parse_args()
    
    # 确定监控目录
    if args.output:
        base_dir = Path(args.output).resolve()
        if not base_dir.exists():
            print(f"❌ 错误: 指定的目录不存在: {base_dir}", file=sys.stderr)
            sys.exit(1)
        if not base_dir.is_dir():
            print(f"❌ 错误: 指定的路径不是目录: {base_dir}", file=sys.stderr)
            sys.exit(1)
    else:
        # 默认使用脚本所在目录
        base_dir = Path(__file__).parent
    
    # 确定检查间隔
    check_interval = args.interval if args.interval else CHECK_INTERVAL
    
    # 发送启动通知
    try:
        # URL encode the base_dir path to handle special characters
        encoded_base_dir = quote(str(base_dir), safe='')
        url = WEBHOOK_URL + f"启动崩溃文件监控器/监控目录: {encoded_base_dir}?level=passive"
        print(f"✉️  发送 HTTP 请求: {url}")
        _response = requests.get(
            url,
            timeout=HTTP_TIMEOUT
        )
        print(f"✉️  发送 HTTP 请求成功: {_response.status_code}")
    except Exception as e:
        print(f"⚠️  启动通知发送失败: {e}")
    
    # 创建监控器并运行
    print(f"🚀 启动崩溃文件监控器")
    print(f"📁 监控根目录: {base_dir}")
    print(f"🔍 监控目录类型: {', '.join(MONITOR_DIRS)}")
    print(f"⏱️  检查间隔: {check_interval} 秒")
    print(f"📡 Webhook: {WEBHOOK_URL}")
    print("-" * 60)
    
    monitor = AsanMonitor(base_dir=base_dir, check_interval=check_interval)
    monitor.run()


if __name__ == "__main__":
    main()
