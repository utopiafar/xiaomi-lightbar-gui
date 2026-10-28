"""Serial connection to the RF-Nano bridge. The lamp does not acknowledge RF."""

import glob
import re
import threading
import time

import serial
from serial.tools import list_ports

ID_RE = re.compile(r"^[0-9A-F]{2}(?::[0-9A-F]{2}){2}$")


class BridgeError(Exception):
    pass


def find_ports():
    """Put CH340 ports first, while still allowing the user to choose others."""
    found = [port for port in list_ports.comports() if port.device.startswith("/dev/cu.")]
    found.sort(key=lambda port: (port.vid != 0x1A86, port.device))
    devices = [port.device for port in found]
    for device in sorted(glob.glob("/dev/cu.usbserial*")):
        if device not in devices:
            devices.append(device)
    return devices


class Bridge:
    def __init__(self, path):
        self.path = path
        self.serial = None
        self.remote_id = None

    def connect(self):
        try:
            self.serial = serial.Serial(self.path, 115200, timeout=0.1, write_timeout=2)
            # Opening a Nano's serial port usually resets it. Wait for the
            # bootloader and use PING instead of depending on a missed banner.
            time.sleep(2.0)
            self.serial.reset_input_buffer()
            response = self.command("PING", expected="READY", timeout=5)
            if response != "READY":
                raise BridgeError(response)
            response = self.command("GET_ID", expected="ID:")
            stored = response[3:]
            self.remote_id = stored if ID_RE.fullmatch(stored) else None
            return self.remote_id
        except Exception:
            self.close()
            raise

    def close(self):
        if self.serial:
            self.serial.close()
            self.serial = None

    def command(self, line, expected="OK", timeout=5):
        if not self.serial or not self.serial.is_open:
            raise BridgeError("串口未连接")
        self.serial.write((line + "\n").encode("ascii"))
        self.serial.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response = self.serial.readline().decode("ascii", errors="replace").strip()
            if not response:
                continue
            if response.startswith("ERR"):
                raise BridgeError(response)
            if response.startswith(expected):
                return response
            # Startup banners and scan packets can be interleaved with replies.
        raise BridgeError(f"设备没有回复 {line}")

    def scan(self, timeout=90, cancelled=None):
        """Read a CRC-validated original remote ID and save it to EEPROM."""
        cancelled = cancelled or threading.Event()
        self.command("SCAN")
        found = None
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline and not cancelled.is_set():
                line = self.serial.readline().decode("ascii", errors="replace").strip()
                if line.startswith("FOUND:"):
                    candidate = line[6:].upper()
                    if ID_RE.fullmatch(candidate):
                        found = candidate
                        break
                elif line.startswith("ERR"):
                    raise BridgeError(line)
        finally:
            self.command("SCAN_STOP")
        if found:
            self.command("ID " + found)
            self.remote_id = found
        return found

    def send(self, command):
        if not self.remote_id:
            raise BridgeError("请先扫描原遥控器")
        return self.command(command)
