#!/usr/bin/env python3
"""
aflnet2nc.py - 将 aflnet-replay 格式转换为可通过 nc 发送的格式

aflnet-replay 格式：
  每个数据包 = [4字节长度(小端)] + [N字节payload]

用法：
  # 方式1：直接输出到 stdout，通过管道发送
  python3 aflnet2nc.py input.bin | nc 127.0.0.1 5158

  # 方式2：保存到文件，然后发送
  python3 aflnet2nc.py input.bin -o output.bin
  nc 127.0.0.1 5158 < output.bin

  # 方式3：指定字节序（默认小端）
  python3 aflnet2nc.py input.bin --byte-order big | nc 127.0.0.1 5158
"""

import argparse
import struct
import sys
from pathlib import Path


def parse_packets(input_path: Path, byte_order: str = "<") -> list[bytes]:
    """解析 aflnet-replay 格式文件，返回所有 payload 列表
    
    格式与 aflnet-replay.c 一致：
    - 每个数据包 = [4字节长度(小端 unsigned int)] + [N字节payload]
    - 循环直到文件结束（feof）
    """
    packets = []
    with input_path.open("rb") as f:
        idx = 0
        while True:
            # 读取长度字段（4字节，对应 C 代码的 sizeof(unsigned int)）
            length_bytes = f.read(4)
            
            # 如果读取失败或不足4字节，说明文件结束（对应 C 代码的 fread > 0 检查）
            if len(length_bytes) == 0:
                break  # 正常结束（EOF）
            if len(length_bytes) < 4:
                print(
                    f"警告：数据包 {idx+1} 的长度字段不完整（只有 {len(length_bytes)} 字节），跳过",
                    file=sys.stderr,
                )
                break

            # 解析长度（默认小端，与 C 代码的 unsigned int 一致）
            fmt = f"{byte_order}I"
            (length,) = struct.unpack(fmt, length_bytes)

            # 读取 payload（对应 C 代码的 fread(buf, size, 1, fp)）
            payload = f.read(length)
            
            # 如果读取的字节数少于期望值，可能是文件截断
            # 但为了保持与原始数据一致，仍然使用实际读取到的数据
            if len(payload) < length:
                print(
                    f"警告：数据包 {idx+1} 期望 {length} 字节，实际 {len(payload)} 字节",
                    file=sys.stderr,
                )
                if len(payload) == 0:
                    # 如果 payload 为空，说明文件可能已结束，退出循环
                    break

            packets.append(payload)
            idx += 1

    return packets


def main():
    parser = argparse.ArgumentParser(
        description="将 aflnet-replay 格式转换为可通过 nc 发送的格式"
    )
    parser.add_argument("input", type=Path, help="aflnet-replay 格式的输入文件")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="输出文件路径（默认输出到 stdout）",
    )
    parser.add_argument(
        "--byte-order",
        choices=("<", ">"),
        default="<",
        help="长度字段的字节序：< 小端（默认），> 大端",
    )
    parser.add_argument(
        "--separate",
        action="store_true",
        help="在每个数据包之间插入分隔符（用于调试）",
    )

    args = parser.parse_args()

    try:
        packets = parse_packets(args.input, args.byte_order)
    except Exception as e:
        print(f"错误：解析文件失败 - {e}", file=sys.stderr)
        sys.exit(1)

    if not packets:
        print("警告：没有找到任何数据包", file=sys.stderr)
        sys.exit(1)

    # 合并所有 payload
    output_data = b""
    for i, pkt in enumerate(packets):
        output_data += pkt
        if args.separate and i < len(packets) - 1:
            output_data += b"\n---PACKET_SEPARATOR---\n"

    # 输出
    if args.output:
        args.output.write_bytes(output_data)
        print(f"已写入 {len(packets)} 个数据包到 {args.output}，总大小 {len(output_data)} 字节", file=sys.stderr)
    else:
        # 输出到 stdout（二进制模式）
        sys.stdout.buffer.write(output_data)
        sys.stdout.buffer.flush()
        print(f"已输出 {len(packets)} 个数据包，总大小 {len(output_data)} 字节", file=sys.stderr)


if __name__ == "__main__":
    main()

