#!/usr/bin/env python3
from __future__ import annotations

"""将指定 output 目录中的 POC（hang/crash）提取出来，保持原有层级并打包。"""

import argparse
import datetime
import shutil
import sys
import tarfile
from pathlib import Path
from typing import Sequence

POC_DIR_WHITELIST: dict[str, Sequence[str]] = {
    "aflnet": ("replayable-hangs", "replayable-crashes"),
    "stateafl": ("replayable-hangs", "replayable-crashes"),
    "sgfuzz": ("crashes",),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "从 output/<run>/ 中抽取 hangs/crashs，保留目录结构并压缩成 tar.gz"
        )
    )
    parser.add_argument("-f", "--fuzzer", required=True, help="fuzzer 名称")
    parser.add_argument("-t", "--target", required=True, help="target 名称，例如 TLS/OpenSSL")
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="output 目录路径（包含多个 run 子目录）",
    )
    parser.add_argument(
        "-d",
        "--dest",
        default=".",
        help="打包结果输出目录（默认当前目录）",
    )
    parser.add_argument(
        "--keep-staging",
        action="store_true",
        help="保留临时抽取目录，默认打包后删除",
    )
    return parser.parse_args()


def validate_dir(path: Path, desc: str) -> None:
    if not path.exists():
        sys.exit(f"[!] {desc} 路径不存在: {path}")
    if not path.is_dir():
        sys.exit(f"[!] {desc} 路径不是目录: {path}")


def gather_runs(output_dir: Path, fuzzer: str, target: str) -> list[Path]:
    target = target.replace("/", "-")
    return sorted([d for d in output_dir.iterdir() if d.is_dir() and d.name.find(fuzzer) != -1 and d.name.find(target) != -1])


def copy_pocs(run_dir: Path, staging_dir: Path, poc_dirs: Sequence[str]) -> bool:
    copied = False
    target_dir = staging_dir / run_dir.name
    for poc_name in poc_dirs:
        src = run_dir / poc_name
        if not src.is_dir():
            continue
        dst = target_dir / poc_name
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst)
        copied = True
    # 如果 run 下没有需要的目录，不保留空目录
    if not copied and target_dir.exists():
        shutil.rmtree(target_dir, ignore_errors=True)
    return copied


def create_archive(staging_dir: Path, archive_path: Path) -> None:
    with tarfile.open(archive_path, "w:gz") as tar:
        tar.add(staging_dir, arcname=staging_dir.name)


def main() -> None:
    args = parse_args()
    output_dir = Path(args.output).resolve()
    dest_root = Path(args.dest).resolve()

    validate_dir(output_dir, "output")
    dest_root.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    bundle_name = f"pocs-{args.fuzzer}-{args.target.replace('/', '_')}-{timestamp}"
    staging_dir = dest_root / bundle_name
    staging_dir.mkdir()

    runs = gather_runs(output_dir, args.fuzzer, args.target)
    if not runs:
        staging_dir.rmdir()
        sys.exit(f"[!] output 目录 {output_dir} 没有任何子目录可处理")

    fuzzer_key = args.fuzzer.lower()
    if fuzzer_key not in POC_DIR_WHITELIST:
        available = ", ".join(sorted(POC_DIR_WHITELIST))
        sys.exit(f"[!] 未知 fuzzer {args.fuzzer}，可选：{available}")
    poc_dirs = POC_DIR_WHITELIST[fuzzer_key]
    copied_runs = 0
    for run_dir in runs:
        if copy_pocs(run_dir, staging_dir, poc_dirs):
            copied_runs += 1

    if copied_runs == 0:
        staging_dir.rmdir()
        sys.exit("[!] 未找到任何符合白名单的 POC 目录，未生成打包文件")

    archive_path = staging_dir.with_suffix(".tar.gz")
    create_archive(staging_dir, archive_path)
    print(f"[+] 已打包 {copied_runs} 个 run 的 POC -> {archive_path}")

    if not args.keep_staging:
        shutil.rmtree(staging_dir)
    else:
        print(f"[i] 临时目录保留在 {staging_dir}")


if __name__ == "__main__":
    main()

