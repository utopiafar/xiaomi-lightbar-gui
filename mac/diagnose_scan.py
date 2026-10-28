#!/usr/bin/env python3
"""Listen on one channel at a time and report raw matching RF frames."""

import argparse
import time
from bridge import Bridge

parser = argparse.ArgumentParser()
parser.add_argument("--port", required=True, help="RF-Nano serial port, e.g. /dev/cu.usbserial-XXXX")
parser.add_argument("--seconds", type=int, default=240)
args = parser.parse_args()
bridge = Bridge(args.port)
channels = [68, 6, 43, 15, 7, 44, 69, 16]

try:
    bridge.connect()
    deadline = time.monotonic() + args.seconds
    print("DIAGNOSTIC_READY", flush=True)
    while time.monotonic() < deadline:
        for channel in channels:
            bridge.command("SCAN_DIAG " + str(channel))
            print("CHANNEL", channel, flush=True)
            channel_deadline = min(deadline, time.monotonic() + 6)
            found = None
            while time.monotonic() < channel_deadline:
                line = bridge.serial.readline().decode("ascii", errors="replace").strip()
                if line.startswith("RAW:") or line.startswith("FOUND:"):
                    print(line, flush=True)
                if line.startswith("FOUND:"):
                    found = line[6:]
                    break
            bridge.command("SCAN_STOP")
            if found:
                bridge.command("ID " + found)
                print("SAVED", found, flush=True)
                raise SystemExit(0)
            if time.monotonic() >= deadline:
                break
    print("DIAGNOSTIC_TIMEOUT", flush=True)
finally:
    bridge.close()
