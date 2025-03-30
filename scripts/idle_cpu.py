#!/usr/bin/env python3
import os
import sys
import subprocess
from typing import Dict, List

def get_cpu_count() -> int:
    """获取系统CPU数量"""
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        # 如果不支持 sched_getaffinity，使用 os.cpu_count()
        return os.cpu_count() or 1

def get_running_containers_cpu() -> Dict[int, str]:
    """获取正在运行的容器已分配的CPU信息
    通过解析容器名称 name-index-cpuX-timestamp 获取CPU ID
    返回: Dict[cpu_number, container_id]
    """
    cpu_allocations: Dict[int, str] = {}
    
    try:
        # 获取所有运行中的容器
        cmd = ["docker", "ps", "--format", "{{.Names}}"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        containers = result.stdout.strip().split('\n')
        
        # 过滤掉空行
        containers = [c for c in containers if c]
        
        for container in containers:
            # 解析容器名称获取CPU ID
            parts = container.split('-')
            for part in parts:
                if part.startswith('cpu'):
                    try:
                        cpu_num = int(part[3:])  # 去掉 'cpu' 前缀
                        cpu_allocations[cpu_num] = container
                    except (ValueError, IndexError):
                        continue
                        
    except subprocess.SubprocessError:
        print("Error running docker commands", file=sys.stderr)
        
    return cpu_allocations

def find_available_cpus(max_cpus: int, allocated_cpus: Dict[int, str], n: int) -> List[int]:
    """找到n个空闲的CPU"""
    all_cpus = set(range(max_cpus))
    used_cpus = set(allocated_cpus.keys())
    free_cpus = sorted(list(all_cpus - used_cpus))
    return free_cpus[:n]

def main():
    if len(sys.argv) != 2:
        print("Usage: idle_cpu.py <number_of_cpus>", file=sys.stderr)
        sys.exit(1)
        
    try:
        n = int(sys.argv[1])
    except ValueError:
        print("Error: argument must be an integer", file=sys.stderr)
        sys.exit(1)
        
    max_cpus = get_cpu_count()
    allocated_cpus = get_running_containers_cpu()
    free_cpus = find_available_cpus(max_cpus, allocated_cpus, n)
    
    if len(free_cpus) < n:
        print(f"Not enough idle CPUs, only {len(free_cpus)} CPUs available", file=sys.stderr)
        sys.exit(1)
        
    print(" ".join(map(str, free_cpus)))

if __name__ == "__main__":
    main()
