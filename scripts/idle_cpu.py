#!/usr/bin/env python3
import os
import sys
import subprocess
from pathlib import Path
from typing import List, Set


FUZZER_CORE_COUNT = {
    "ft": 4,
    "aflnet": 4,
    "stateafl": 4,
    "sgfuzz": 4,
}


def parse_cpu_range_spec(spec: str) -> List[int]:
    """Parse cpu range string like '0-3,8,10-12' to sorted unique cpu ids."""
    cpus: Set[int] = set()
    for chunk in spec.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "-" in chunk:
            left, right = chunk.split("-", 1)
            start = int(left)
            end = int(right)
            if end < start:
                start, end = end, start
            cpus.update(range(start, end + 1))
        else:
            cpus.add(int(chunk))
    return sorted(cpus)


def get_online_cpus() -> List[int]:
    """Get logical CPUs from host online list (/sys/devices/system/cpu/online)."""
    online_path = "/sys/devices/system/cpu/online"
    try:
        with open(online_path, "r", encoding="utf-8") as f:
            content = f.read().strip()
        if content:
            return parse_cpu_range_spec(content)
    except (OSError, ValueError):
        pass

    # Fallback for environments where /sys is unavailable.
    try:
        return sorted(os.sched_getaffinity(0))
    except AttributeError:
        count = os.cpu_count() or 1
        return list(range(count))


def parse_start_cpu(container_name: str) -> int:
    """Parse cpuX in container name and return X, -1 if not found."""
    for part in container_name.split("-"):
        if part.startswith("cpu"):
            tail = part[3:]
            if tail.isdigit():
                return int(tail)
    return -1


def infer_container_core_count(container_name: str) -> int:
    """
    Infer cores per container from name pattern:
    pingu-<fuzzer>-...-cpuX-<timestamp>
    """
    parts = container_name.split("-")
    if len(parts) >= 2 and parts[0] == "pingu":
        return FUZZER_CORE_COUNT.get(parts[1], 1)
    return 1


def get_running_containers_allocated_cpus(online_cpus: List[int]) -> Set[int]:
    """Collect logical CPUs already allocated by running containers."""
    allocated: Set[int] = set()
    online = set(online_cpus)

    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            check=False,
        )
        containers = [c for c in result.stdout.strip().split("\n") if c]
        for container in containers:
            start_cpu = parse_start_cpu(container)
            if start_cpu < 0:
                continue
            core_count = infer_container_core_count(container)
            for cpu in range(start_cpu, start_cpu + core_count):
                if cpu in online:
                    allocated.add(cpu)
    except subprocess.SubprocessError:
        print("Error running docker commands", file=sys.stderr)

    return allocated


def get_running_container_names() -> Set[str]:
    """Get the set of currently running container names."""
    names: Set[str] = set()
    try:
        result = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True,
            text=True,
            check=False,
        )
        for line in result.stdout.strip().split("\n"):
            if line:
                names.add(line)
    except subprocess.SubprocessError:
        print("Error running docker commands", file=sys.stderr)
    return names


def get_output_allocated_cpus(
    online_cpus: List[int], output_dir: str, running_containers: Set[str]
) -> Set[int]:
    """
    Collect logical CPUs from output/*/attached_core for running containers only.
    Stopped containers are treated as released and therefore ignored.
    """
    allocated: Set[int] = set()
    online = set(online_cpus)
    root = Path(output_dir)
    if not root.exists():
        return allocated

    for f in root.glob("*/attached_core"):
        # Directory name is the container name used by scripts/run.sh.
        # Ignore stale output from stopped containers.
        if f.parent.name not in running_containers:
            continue
        try:
            raw = f.read_text(encoding="utf-8").strip()
        except OSError:
            continue
        if not raw or raw == "none":
            continue
        try:
            for cpu in parse_cpu_range_spec(raw):
                if cpu in online:
                    allocated.add(cpu)
        except ValueError:
            # Ignore malformed records.
            continue

    return allocated


def find_available_cpu_groups(
    online_cpus: List[int], used_cpus: Set[int], n: int, cores_per_container: int
) -> List[int]:
    """
    Return n start CPU indices for contiguous CPU groups of size cores_per_container.
    """
    online = set(online_cpus)
    starts: List[int] = []
    reserved = set(used_cpus)

    for start in online_cpus:
        group = list(range(start, start + cores_per_container))
        if all(c in online for c in group) and all(c not in reserved for c in group):
            starts.append(start)
            reserved.update(group)
            if len(starts) >= n:
                break
    return starts


def main() -> None:
    if len(sys.argv) not in (2, 3, 4):
        print(
            "Usage: idle_cpu.py <number_of_containers> [cores_per_container] [output_dir]",
            file=sys.stderr,
        )
        sys.exit(1)

    try:
        n = int(sys.argv[1])
        cores_per_container = int(sys.argv[2]) if len(sys.argv) >= 3 else 1
    except ValueError:
        print("Error: arguments must be integers", file=sys.stderr)
        sys.exit(1)

    if n <= 0 or cores_per_container <= 0:
        print("Error: arguments must be positive integers", file=sys.stderr)
        sys.exit(1)

    output_dir = sys.argv[3] if len(sys.argv) == 4 else "output"

    online_cpus = get_online_cpus()
    running_containers = get_running_container_names()
    used_cpus = get_running_containers_allocated_cpus(online_cpus)
    used_cpus.update(get_output_allocated_cpus(online_cpus, output_dir, running_containers))
    starts = find_available_cpu_groups(online_cpus, used_cpus, n, cores_per_container)

    if len(starts) < n:
        print(
            f"Not enough idle CPU groups, only {len(starts)} group(s) available "
            f"for {cores_per_container} core(s) each",
            file=sys.stderr,
        )
        sys.exit(1)

    print(" ".join(map(str, starts)))


if __name__ == "__main__":
    main()
