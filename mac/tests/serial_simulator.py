"""Run the native serial bridge against a simulated RF-Nano over a PTY."""

import os
import pty
import select
import subprocess
import sys
import time
import tty

master, slave = pty.openpty()
tty.setraw(slave)
mode = sys.argv[2] if len(sys.argv) > 2 else "scan"
process = subprocess.Popen([sys.argv[1], os.ttyname(slave), mode], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
commands = []
pending = b""
deadline = time.monotonic() + 15
try:
    while process.poll() is None and time.monotonic() < deadline:
        if not select.select([master], [], [], 0.1)[0]:
            continue
        pending += os.read(master, 1024)
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            command = line.decode("ascii").strip()
            commands.append(command)
            if command == "PING":
                response = b"READY\n"
            elif command == "GET_ID":
                response = b"ID:none\n"
            elif command == "SCAN":
                response = b"OK\nFOUND:0A:05:F1\nFOUND:0A:05:F1\n"
            else:
                response = b"OK\n"
            os.write(master, response)
    if process.poll() is None:
        process.kill()
        raise RuntimeError("native serial integration test timed out")
    stdout, stderr = process.communicate()
    if process.returncode:
        raise RuntimeError(stderr.decode(errors="replace"))
    if mode == "pair":
        expected = ["PING", "GET_ID", "ID 12:34:56", "PAIR", "ON"]
    elif mode == "sliders":
        expected = ["PING", "GET_ID", "SCAN", "SCAN_STOP", "ID 0A:05:F1",
                    "CMD 04 F0", "CMD 04 00", "CMD 04 F0", "CMD 04 0F",
                    "CMD 02 F0", "CMD 02 07"]
    else:
        expected = ["PING", "GET_ID", "SCAN", "SCAN_STOP", "ID 0A:05:F1", "BRIGHT +3"]
    assert commands == expected, (commands, expected)
    print(stdout.decode().strip())
finally:
    if process.poll() is None:
        process.kill()
        process.wait()
    os.close(master)
    os.close(slave)
