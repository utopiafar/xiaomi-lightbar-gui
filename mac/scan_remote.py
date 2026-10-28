#!/usr/bin/env python3
"""Capture the original remote once without re-pairing the lamp."""

import argparse
import sys

from bridge import Bridge, find_ports

parser = argparse.ArgumentParser()
parser.add_argument("--port", default=None)
parser.add_argument("--timeout", type=float, default=180)
args = parser.parse_args()
ports = find_ports()
port = args.port or (ports[0] if ports else None)
if not port:
    sys.exit("未找到 USB 串口")
bridge = Bridge(port)
try:
    stored = bridge.connect()
    print(f"设备已就绪：{port}；已存编号：{stored or '无'}", flush=True)
    print("正在扫描。请将原遥控器靠近 RF-Nano，持续缓慢旋转。", flush=True)
    found = bridge.scan(timeout=args.timeout)
    if found:
        print(f"扫描成功并已保存：{found}", flush=True)
    else:
        print("扫描超时，未捕获到经过校验的遥控器信号。", flush=True)
        sys.exit(2)
except Exception as exc:
    print(f"错误：{exc}", file=sys.stderr, flush=True)
    sys.exit(1)
finally:
    bridge.close()
