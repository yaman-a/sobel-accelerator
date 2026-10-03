#!/usr/bin/env python3
"""Pretend to be the FPGA, for testing fpga_sobel.py without a board.

    python mock_fpga.py 5000 [--corrupt] [--drop N] [--silent]
    python fpga_sobel.py img.png --port socket://localhost:5000
"""
import argparse
import socket
import sys

import numpy as np

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")
from fpga_sobel import sobel_reference


def recv_exact(c, n):
    buf = bytearray()
    while len(buf) < n:
        d = c.recv(n - len(buf))
        if not d:
            raise ConnectionError("closed")
        buf += d
    return bytes(buf)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", type=int)
    ap.add_argument("--corrupt", action="store_true", help="flip one result byte")
    ap.add_argument("--drop", type=int, default=0, help="omit the last N result bytes")
    ap.add_argument("--silent", action="store_true", help="never answer")
    a = ap.parse_args()
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("localhost", a.port))
    s.listen(1)
    print("mock FPGA listening on", a.port, flush=True)
    c, _ = s.accept()
    hdr = recv_exact(c, 4)
    w, h = (hdr[0] << 8) | hdr[1], (hdr[2] << 8) | hdr[3]
    img = np.frombuffer(recv_exact(c, w * h), dtype=np.uint8).reshape(h, w)
    out = bytearray(sobel_reference(img).tobytes())
    if a.corrupt:
        out[len(out) // 2] ^= 0x55
    if a.drop:
        out = out[:-a.drop]
    if not a.silent:
        c.sendall(bytes(out))
    print(f"served {w}x{h}", flush=True)
    try:
        c.recv(1)
    except Exception:
        pass


if __name__ == "__main__":
    main()
