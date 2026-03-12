#!/usr/bin/env python3
import argparse
import ipaddress
import struct
from pathlib import Path


DLT_EN10MB = 1
DLT_NULL = 0
DLT_RAW = 101
DLT_LINUX_SLL = 113
DLT_LINUX_SLL2 = 276


def parse_args():
    p = argparse.ArgumentParser(description="Extract client->server TCP/UDP payloads from pcap and build seed files")
    p.add_argument("--pcap", required=True, type=Path)
    p.add_argument("--transport", choices=["tcp", "udp"], required=True)
    p.add_argument("--server-port", type=int, required=True)
    p.add_argument("--server-ip", default="127.0.0.1")
    p.add_argument("--client-ip", default=None)
    p.add_argument("--seed-path", required=True, type=Path)
    p.add_argument("--seed-replay-path", required=True, type=Path)
    p.add_argument("--seed-mode", choices=["first", "concat"], default="first")
    return p.parse_args()


def read_pcap_records(fp):
    gh = fp.read(24)
    if len(gh) != 24:
        raise ValueError("Invalid pcap: global header too short")

    magic = gh[:4]
    if magic == b"\xd4\xc3\xb2\xa1" or magic == b"\x4d\x3c\xb2\xa1":
        endian = "<"
    elif magic == b"\xa1\xb2\xc3\xd4" or magic == b"\xa1\xb2\x3c\x4d":
        endian = ">"
    else:
        raise ValueError("Unsupported pcap magic")

    _, _, _, _, _, _, network = struct.unpack(endian + "IHHIIII", gh)

    while True:
        ph = fp.read(16)
        if not ph:
            break
        if len(ph) != 16:
            raise ValueError("Invalid pcap: packet header truncated")
        _, _, incl_len, _ = struct.unpack(endian + "IIII", ph)
        data = fp.read(incl_len)
        if len(data) != incl_len:
            raise ValueError("Invalid pcap: packet data truncated")
        yield network, data


def parse_ipv4_packet(data):
    if len(data) < 20:
        return None
    ver_ihl = data[0]
    if ver_ihl >> 4 != 4:
        return None
    ihl = (ver_ihl & 0x0F) * 4
    if len(data) < ihl:
        return None
    proto = data[9]
    src = str(ipaddress.ip_address(data[12:16]))
    dst = str(ipaddress.ip_address(data[16:20]))
    return proto, src, dst, data[ihl:]


def parse_ipv6_packet(data):
    if len(data) < 40:
        return None
    if data[0] >> 4 != 6:
        return None
    nh = data[6]
    src = str(ipaddress.ip_address(data[8:24]))
    dst = str(ipaddress.ip_address(data[24:40]))
    return nh, src, dst, data[40:]


def parse_l4_payload(transport, l4):
    if transport == "udp":
        if len(l4) < 8:
            return None
        src_port, dst_port, _, _ = struct.unpack("!HHHH", l4[:8])
        return src_port, dst_port, l4[8:]

    if len(l4) < 20:
        return None
    src_port, dst_port = struct.unpack("!HH", l4[:4])
    data_offset = ((l4[12] >> 4) & 0x0F) * 4
    if len(l4) < data_offset:
        return None
    return src_port, dst_port, l4[data_offset:]


def decode_frame(linktype, frame):
    if linktype == DLT_EN10MB:
        if len(frame) < 14:
            return None
        ether_type = struct.unpack("!H", frame[12:14])[0]
        if ether_type == 0x0800:
            return parse_ipv4_packet(frame[14:])
        if ether_type == 0x86DD:
            return parse_ipv6_packet(frame[14:])
        return None

    if linktype == DLT_LINUX_SLL:
        if len(frame) < 16:
            return None
        proto = struct.unpack("!H", frame[14:16])[0]
        payload = frame[16:]
        if proto == 0x0800:
            return parse_ipv4_packet(payload)
        if proto == 0x86DD:
            return parse_ipv6_packet(payload)
        return None

    if linktype == DLT_LINUX_SLL2:
        if len(frame) < 20:
            return None
        proto = struct.unpack("!H", frame[0:2])[0]
        payload = frame[20:]
        if proto == 0x0800:
            return parse_ipv4_packet(payload)
        if proto == 0x86DD:
            return parse_ipv6_packet(payload)
        return None

    if linktype == DLT_RAW:
        if not frame:
            return None
        v = frame[0] >> 4
        if v == 4:
            return parse_ipv4_packet(frame)
        if v == 6:
            return parse_ipv6_packet(frame)
        return None

    if linktype == DLT_NULL:
        if len(frame) < 4:
            return None
        family = struct.unpack("<I", frame[:4])[0]
        payload = frame[4:]
        if family in (2,):
            return parse_ipv4_packet(payload)
        if family in (24, 28, 30):
            return parse_ipv6_packet(payload)
        return None

    return None


def main():
    args = parse_args()
    server_ip = str(ipaddress.ip_address(args.server_ip))
    client_ip = str(ipaddress.ip_address(args.client_ip)) if args.client_ip else None

    transport_proto = 17 if args.transport == "udp" else 6
    payloads = []

    with args.pcap.open("rb") as fp:
        for linktype, frame in read_pcap_records(fp):
            decoded = decode_frame(linktype, frame)
            if not decoded:
                continue
            proto, src_ip, dst_ip, l4 = decoded
            if proto != transport_proto:
                continue

            l4_parsed = parse_l4_payload(args.transport, l4)
            if not l4_parsed:
                continue
            src_port, dst_port, payload = l4_parsed

            if dst_port != args.server_port:
                continue
            if src_port == args.server_port:
                continue
            if dst_ip != server_ip:
                continue
            if client_ip and src_ip != client_ip:
                continue
            if not payload:
                continue

            payloads.append(payload)

    if not payloads:
        raise SystemExit("No client->server payload found in pcap")

    args.seed_path.parent.mkdir(parents=True, exist_ok=True)
    args.seed_replay_path.parent.mkdir(parents=True, exist_ok=True)

    if args.seed_mode == "first":
        seed_bytes = payloads[0]
    else:
        seed_bytes = b"".join(payloads)

    args.seed_path.write_bytes(seed_bytes)

    with args.seed_replay_path.open("wb") as fp:
        for p in payloads:
            fp.write(struct.pack("<I", len(p)))
            fp.write(p)

    print(f"Extracted payload packets: {len(payloads)}")
    print(f"seed: {args.seed_path} ({len(seed_bytes)} bytes)")
    print(f"seed-replay: {args.seed_replay_path}")


if __name__ == "__main__":
    main()
