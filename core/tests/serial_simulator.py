"""Exercise the public C interface against a simulated RF-Nano over a PTY.

Run on Linux after building the Rust cdylib. On macOS the serialport crate
cannot apply a hardware baud rate to a pseudo-terminal.
    python3 core/tests/serial_simulator.py path/to/liblightbar_core.so
"""
import ctypes
import json
import os
import pty
import select
import sys
import time
import tty


library = ctypes.CDLL(os.path.abspath(sys.argv[1]))
library.lightbar_create.restype = ctypes.c_void_p
library.lightbar_send.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
library.lightbar_send.restype = ctypes.c_int32
library.lightbar_next_event.argtypes = [ctypes.c_void_p]
library.lightbar_next_event.restype = ctypes.c_void_p
library.lightbar_free_string.argtypes = [ctypes.c_void_p]
library.lightbar_destroy.argtypes = [ctypes.c_void_p]

master, slave = pty.openpty()
tty.setraw(slave)
controller = library.lightbar_create()
commands = []
events = []
pending = b""
sent_control = False

def request(**payload):
    assert library.lightbar_send(controller, json.dumps(payload).encode()) == 0

try:
    request(type="connect", path=os.ttyname(slave))
    deadline = time.monotonic() + 18
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.02)[0]:
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
                    # Deliberately put the acknowledgement and remote packet
                    # in the same read to catch buffered-reader regressions.
                    response = b"OK\nFOUND:0A:05:F1\nFOUND:0A:05:F1\n"
                else:
                    response = b"OK\n"
                os.write(master, response)
        while pointer := library.lightbar_next_event(controller):
            try:
                event = json.loads(ctypes.string_at(pointer).decode())
                events.append(event)
            finally:
                library.lightbar_free_string(pointer)
            if event.get("type") == "error":
                raise RuntimeError(event["message"])
            if event.get("status") == "remote_saved" and not sent_control:
                request(type="brightness", value=15)
                request(type="temperature", value=7)
                request(type="toggle")
                sent_control = True
        if commands[-5:] == ["CMD 04 F0", "CMD 04 0F", "CMD 02 F0", "CMD 02 07", "ON"]:
            break
    else:
        raise RuntimeError(f"serial simulator timed out; commands={commands!r}; events={events!r}")

    assert commands == ["PING", "GET_ID", "SCAN", "SCAN_STOP", "ID 0A:05:F1", "CMD 04 F0", "CMD 04 0F", "CMD 02 F0", "CMD 02 07", "ON"], commands
    print("Rust C interface and serial simulator passed")
finally:
    library.lightbar_destroy(controller)
    os.close(master)
    os.close(slave)
