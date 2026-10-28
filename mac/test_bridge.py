"""Exercise the Mac handshake and scan with a simulated serial bridge."""

from collections import deque
import unittest
from unittest.mock import patch

from bridge import Bridge


class SimulatedSerial:
    def __init__(self, *args, **kwargs):
        self.is_open = True
        self.commands = []
        self.replies = deque()

    def write(self, raw):
        command = raw.decode("ascii").strip()
        self.commands.append(command)
        if command == "PING":
            self.replies.append(b"READY\n")
        elif command == "GET_ID":
            self.replies.append(b"ID:none\n")
        elif command == "SCAN":
            # Repeated RF packets may already be buffered when scan stops.
            self.replies.extend([b"OK\n", b"FOUND:0A:05:F1\n", b"FOUND:0A:05:F1\n"])
        else:
            self.replies.append(b"OK\n")
        return len(raw)

    def readline(self):
        return self.replies.popleft() if self.replies else b""

    def flush(self):
        pass

    def reset_input_buffer(self):
        self.replies.clear()

    def close(self):
        self.is_open = False


class BridgeTest(unittest.TestCase):
    @patch("bridge.time.sleep")
    @patch("bridge.serial.Serial", SimulatedSerial)
    def test_capture_saves_original_id_before_transmission(self, unused_sleep):
        bridge = Bridge("/dev/fake")
        try:
            self.assertIsNone(bridge.connect())
            self.assertEqual(bridge.scan(timeout=3), "0A:05:F1")
            self.assertEqual(bridge.send("BRIGHT +3"), "OK")
            self.assertEqual(bridge.serial.commands,
                             ["PING", "GET_ID", "SCAN", "SCAN_STOP", "ID 0A:05:F1", "BRIGHT +3"])
        finally:
            bridge.close()


if __name__ == "__main__":
    unittest.main()
