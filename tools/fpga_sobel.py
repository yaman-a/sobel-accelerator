#!/usr/bin/env python3
"""Send an image to the Basys3 Sobel design over USB-UART and save the result.

    py tools\\fpga_sobel.py photo.jpg --port COM5

Needs:  pip install pyserial numpy pillow

Protocol (8N1): width (2 bytes, big endian), height (2 bytes), then the pixels
row by row. The FPGA returns (width-2)*(height-2) bytes, the Sobel result for
the interior pixels; this script puts the zero border back, saves a PNG and
checks every pixel against a software Sobel.

Exit code: 0 = matches, 1 = mismatch, 2 = FPGA stopped answering.
"""
import argparse
import sys
import threading
import time
from pathlib import Path

import numpy as np
import serial
from PIL import Image, ImageOps

HARD_MAX_WIDTH = 640     # line buffer depth in the FPGA


def load_gray(path, max_w, max_h):
    img = Image.open(path)
    img = ImageOps.exif_transpose(img).convert("L")
    if img.width > max_w or img.height > max_h:
        img.thumbnail((max_w, max_h), Image.LANCZOS)
    return np.asarray(img, dtype=np.uint8)


def sobel_reference(a):
    """|gx| + |gy| clamped to 255 for the interior pixels, same as the hardware."""
    p = a.astype(np.int32)
    gx = (p[:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:]) - (p[:-2, :-2] + 2 * p[1:-1, :-2] + p[2:, :-2])
    gy = (p[2:, :-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) - (p[:-2, :-2] + 2 * p[:-2, 1:-1] + p[:-2, 2:])
    return np.minimum(np.abs(gx) + np.abs(gy), 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image")
    ap.add_argument("--port", required=True, help="COM port (Windows) or e.g. socket://localhost:5000")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--max-width", type=int, default=320, help="shrink larger images (hard limit 640)")
    ap.add_argument("--max-height", type=int, default=240)
    ap.add_argument("--out", help="output PNG (default: <image>_fpga_sobel.png)")
    ap.add_argument("--timeout", type=float, default=3.0, help="seconds without any reply before giving up")
    args = ap.parse_args()

    if args.max_width > HARD_MAX_WIDTH:
        sys.exit(f"--max-width cannot exceed {HARD_MAX_WIDTH}")

    gray = load_gray(args.image, args.max_width, args.max_height)
    h, w = gray.shape
    if w < 3 or h < 3:
        sys.exit("Image must be at least 3x3")
    expected = (w - 2) * (h - 2)
    print(f"Image {w}x{h}: sending {w * h} bytes, expecting {expected} back at {args.baud} baud")

    ser = serial.serial_for_url(args.port, baudrate=args.baud, timeout=0.2, write_timeout=10)
    ser.reset_input_buffer()

    payload = bytes([w >> 8, w & 255, h >> 8, h & 255]) + gray.tobytes()
    write_error = []

    def writer():
        try:
            for i in range(0, len(payload), 512):
                ser.write(payload[i:i + 512])
            ser.flush()
        except Exception as e:           # reported from the main thread
            write_error.append(e)

    t0 = time.time()
    th = threading.Thread(target=writer, daemon=True)
    th.start()

    # The FPGA answers while the image is still being sent, so we must read at the
    # same time or the PC's receive buffer can overflow.
    got = bytearray()
    last_progress = time.time()
    while len(got) < expected:
        chunk = ser.read(min(4096, expected - len(got)))
        if chunk:
            got += chunk
            last_progress = time.time()
        elif write_error:
            sys.exit(f"Write failed: {write_error[0]}")
        elif time.time() - last_progress > args.timeout and not th.is_alive():
            break
        elif time.time() - last_progress > args.timeout + 30:
            break
    th.join(timeout=1)
    elapsed = time.time() - t0
    ser.close()

    if len(got) < expected:
        print(f"TIMEOUT: got {len(got)} of {expected} bytes after {elapsed:.1f} s")
        print("Check: bitstream programmed? correct COM port? baud rate matches CLKS_PER_BIT?")
        print("LEDs: LED2 = bad header, LED3 = UART framing error, LED4 = FIFO overflow")
        print("      (press the centre button to reset the FPGA, then try again)")
        return 2

    result = np.zeros((h, w), dtype=np.uint8)
    result[1:-1, 1:-1] = np.frombuffer(bytes(got), dtype=np.uint8).reshape(h - 2, w - 2)

    ref = np.zeros((h, w), dtype=np.uint8)
    ref[1:-1, 1:-1] = sobel_reference(gray)
    bad = np.argwhere(result != ref)

    out = Path(args.out) if args.out else Path(args.image).with_name(Path(args.image).stem + "_fpga_sobel.png")
    Image.fromarray(result).save(out)
    print(f"Saved {out}  ({elapsed:.1f} s, {len(payload) * 10 / elapsed / 1e3:.0f} kbit/s on the wire)")

    if len(bad) == 0:
        print("OK: every pixel matches the software Sobel.")
        return 0
    print(f"MISMATCH: {len(bad)} of {w * h} pixels differ. First few (row, col, fpga, expected):")
    for y, x in bad[:5]:
        print(f"  {y}, {x}, {result[y, x]}, {ref[y, x]}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
