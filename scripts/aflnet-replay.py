#!/usr/bin/env python3
"""
aflnet-replay.py - Python 版本的 aflnet-replay

模仿 aflnet-replay.c 的行为：
  1. 从输入文件读取 aflnet-replay 格式的数据包（4字节长度 + payload）
  2. 建立 TCP/UDP 连接到服务器
  3. 逐个发送数据包
  4. 可选：接收并显示服务器响应

用法：
  python3 aflnet-replay.py packet_file protocol port [first_resp_timeout_ms] [follow-up_resp_timeout_us]

示例：
  python3 aflnet-replay.py crash.bin DICOM 5158
  python3 aflnet-replay.py crash.bin RTSP 8554 1 1000
"""

import argparse
import socket
import struct
import sys
import time
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="重放 aflnet-replay 格式的数据包到目标服务器"
    )
    parser.add_argument("packet_file", type=Path, help="aflnet-replay 格式的输入文件")
    parser.add_argument(
        "protocol",
        choices=[
            "RTSP",
            "FTP",
            "MQTT",
            "DNS",
            "DTLS12",
            "DICOM",
            "SMTP",
            "SSH",
            "TLS",
            "SIP",
            "HTTP",
            "IPP",
            "SNMP",
            "TFTP",
            "NTP",
            "DHCP",
            "SNTP",
        ],
        help="应用层协议（用于确定使用 TCP 还是 UDP）",
    )
    parser.add_argument("port", type=int, help="服务器端口号")
    parser.add_argument(
        "first_resp_timeout",
        type=int,
        nargs="?",
        default=1,
        help="首次响应超时（毫秒），默认 1",
    )
    parser.add_argument(
        "follow_up_resp_timeout",
        type=int,
        nargs="?",
        default=1000,
        help="后续响应超时（微秒），默认 1000",
    )
    parser.add_argument(
        "--byte-order",
        choices=("<", ">"),
        default="<",
        help="长度字段的字节序：< 小端（默认），> 大端",
    )
    parser.add_argument(
        "--no-recv",
        action="store_true",
        help="不接收服务器响应（仅发送）",
    )
    parser.add_argument(
        "--server-addr",
        default="127.0.0.1",
        help="服务器地址，默认 127.0.0.1",
    )
    return parser.parse_args()


def create_socket(protocol: str):
    """根据协议类型创建 TCP 或 UDP socket"""
    if protocol in ("DTLS12", "DNS", "SIP"):
        return socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    else:
        return socket.socket(socket.AF_INET, socket.SOCK_STREAM)


def connect_with_retry(sock: socket.socket, server_addr: str, port: int, max_retries: int = 1000):
    """尝试连接服务器，失败时重试（模仿 C 代码的重试逻辑）"""
    for n in range(max_retries):
        try:
            sock.connect((server_addr, port))
            return True
        except (socket.error, OSError):
            if n < max_retries - 1:
                time.sleep(0.001)  # 1ms，对应 C 代码的 usleep(1000)
            else:
                return False
    return False


def read_packet(f, byte_order: str = "<"):
    """从文件读取一个数据包（4字节长度 + payload）"""
    # 读取长度字段（4字节，对应 C 代码的 sizeof(unsigned int)）
    length_bytes = f.read(4)
    if len(length_bytes) == 0:
        return None  # EOF
    if len(length_bytes) < 4:
        raise ValueError(f"长度字段不完整：只有 {len(length_bytes)} 字节")

    # 解析长度（小端，对应 C 代码的 unsigned int）
    fmt = f"{byte_order}I"
    length = struct.unpack(fmt, length_bytes)[0]

    # 读取 payload
    payload = f.read(length)
    if len(payload) < length:
        print(
            f"警告：期望 {length} 字节，实际 {len(payload)} 字节",
            file=sys.stderr,
        )

    return payload


def recv_response(sock: socket.socket, timeout: float) -> bytes:
    """接收服务器响应（带超时）"""
    try:
        sock.settimeout(timeout)
        data = sock.recv(4096)
        return data
    except socket.timeout:
        return b""
    except socket.error:
        return b""


def main():
    args = parse_args()

    # 等待服务器初始化（对应 C 代码的 server_wait_usecs = 10000）
    time.sleep(0.01)  # 10ms

    # 打开输入文件
    try:
        fp = args.packet_file.open("rb")
    except Exception as e:
        print(f"错误：无法打开文件 {args.packet_file}: {e}", file=sys.stderr)
        sys.exit(1)

    # 创建 socket
    try:
        sock = create_socket(args.protocol)
    except Exception as e:
        print(f"错误：无法创建 socket: {e}", file=sys.stderr)
        fp.close()
        sys.exit(1)

    # 设置发送超时（对应 C 代码的 SO_SNDTIMEO）
    timeout_sec = args.follow_up_resp_timeout / 1000000.0  # 微秒转秒
    sock.settimeout(timeout_sec)

    # 连接服务器（带重试）
    if not connect_with_retry(sock, args.server_addr, args.port):
        print(
            f"错误：无法连接到 {args.server_addr}:{args.port}",
            file=sys.stderr,
        )
        sock.close()
        fp.close()
        sys.exit(1)

    print(f"已连接到 {args.server_addr}:{args.port}", file=sys.stderr)

    # 发送数据包
    packet_count = 0
    all_responses = b""

    try:
        while True:
            # 读取数据包（对应 C 代码的 while(!feof(fp)) 循环）
            payload = read_packet(fp, args.byte_order)
            if payload is None:
                break  # EOF

            packet_count += 1
            size = len(payload)
            print(f"\n数据包 {packet_count} 的大小: {size}", file=sys.stderr)

            # 接收响应（在发送前，对应 C 代码的第一个 net_recv）
            if not args.no_recv:
                timeout = args.first_resp_timeout / 1000.0 if packet_count == 1 else args.follow_up_resp_timeout / 1000000.0
                response = recv_response(sock, timeout)
                if response:
                    all_responses += response

            # 发送数据包（对应 C 代码的 net_send）
            try:
                sent = sock.send(payload)
                if sent != size:
                    print(
                        f"警告：只发送了 {sent}/{size} 字节",
                        file=sys.stderr,
                    )
                    break
            except socket.error as e:
                print(f"错误：发送失败: {e}", file=sys.stderr)
                break

            # 接收响应（在发送后，对应 C 代码的第二个 net_recv）
            if not args.no_recv:
                timeout = args.first_resp_timeout / 1000.0 if packet_count == 1 else args.follow_up_resp_timeout / 1000000.0
                response = recv_response(sock, timeout)
                if response:
                    all_responses += response

    except Exception as e:
        print(f"错误：处理数据包时出错: {e}", file=sys.stderr)
    finally:
        sock.close()
        fp.close()

    # 显示响应信息（简化版，C 代码会提取状态码）
    if all_responses and not args.no_recv:
        print("\n" + "=" * 40, file=sys.stderr)
        print("服务器响应详情:", file=sys.stderr)
        try:
            print(all_responses.decode("utf-8", errors="replace"), file=sys.stderr)
        except:
            print(f"<二进制数据，{len(all_responses)} 字节>", file=sys.stderr)
        print("=" * 40, file=sys.stderr)

    print(f"\n完成：发送了 {packet_count} 个数据包", file=sys.stderr)


if __name__ == "__main__":
    main()

