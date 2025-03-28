#!/usr/bin/env python3
import os
import sys
from pathlib import Path
from typing import Dict, List

def get_cpu_count() -> int:
    """获取系统CPU数量"""
    try:
        return len(os.sched_getaffinity(0))
    except AttributeError:
        # 如果不支持 sched_getaffinity，使用 os.cpu_count()
        return os.cpu_count() or 1

def read_cpu_allocations(output_dir: str) -> Dict[int, float]:
    """读取所有已分配的CPU信息
    返回: Dict[cpu_number, allocation_time]
    """
    cpu_times: Dict[int, float] = {}
    
    # 遍历output目录下的所有文件夹
    for dir_path in Path(output_dir).iterdir():
        if not dir_path.is_dir():
            continue
            
        core_file = dir_path / "attached_core"
        if not core_file.exists():
            continue
            
        try:
            # 读取CPU编号
            cpu_num = int(core_file.read_text().strip())
            # 获取文件创建时间
            create_time = core_file.stat().st_mtime
            cpu_times[cpu_num] = create_time
        except (ValueError, OSError):
            continue
            
    return cpu_times

def find_available_cpus(max_cpus: int, allocated_cpus: Dict[int, float], n: int) -> List[int]:
    """找到n个空闲的CPU"""
    all_cpus = set(range(max_cpus))
    used_cpus = set(allocated_cpus.keys())
    free_cpus = sorted(list(all_cpus - used_cpus))
    return free_cpus[:n]

def main():
    if len(sys.argv) != 2:
        sys.exit(1)
        
    try:
        n = int(sys.argv[1])
    except ValueError:
        sys.exit(1)
        
    output_dir = "output"
    max_cpus = get_cpu_count()
    allocated_cpus = read_cpu_allocations(output_dir)
    free_cpus = find_available_cpus(max_cpus, allocated_cpus, n)
    
    if len(free_cpus) < n:
        print(f"Not enough idle CPUs, only {len(free_cpus)} CPUs available")
        sys.exit(1)
        
    print(" ".join(map(str, free_cpus)))

if __name__ == "__main__":
    main()
