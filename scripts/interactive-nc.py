#!/usr/bin/env python3
"""
Simple interactive aflnet-replay implementation:
  Connect → Read packet → Send → Receive response → Loop
"""

import socket
import struct
import sys
import time

if len(sys.argv) < 4:
    print(f"Usage: {sys.argv[0]} <input_file> <server_ip> <port>")
    sys.exit(1)

input_file = sys.argv[1]
server_ip = sys.argv[2]
server_port = int(sys.argv[3])

# Wait for server initialization
time.sleep(0.01)

# Establish connection
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.connect((server_ip, server_port))
print(f"Connected to {server_ip}:{server_port}", file=sys.stderr)

# Open file and send packets in loop
with open(input_file, "rb") as f:
    packet_count = 0
    while True:
        # Read 4-byte length (little-endian)
        length_bytes = f.read(4)
        if len(length_bytes) == 0:
            break  # EOF
        if len(length_bytes) < 4:
            break

        length = struct.unpack("<I", length_bytes)[0]

        # Read payload
        payload = f.read(length)
        if len(payload) == 0:
            break

        packet_count += 1
        print(f"Packet {packet_count}: size={len(payload)}", file=sys.stderr)

        # Receive response (before sending)
        try:
            sock.settimeout(0.1)
            response = sock.recv(4096)
            if response:
                print(f"Received response: {len(response)} bytes", file=sys.stderr)
        except socket.timeout:
            pass

        # Send packet
        sock.sendall(payload)

        # Receive response (after sending)
        try:
            sock.settimeout(0.1)
            response = sock.recv(4096)
            if response:
                print(f"Received response: {len(response)} bytes", file=sys.stderr)
        except socket.timeout:
            pass

sock.close()
print(f"Done: sent {packet_count} packets", file=sys.stderr)
