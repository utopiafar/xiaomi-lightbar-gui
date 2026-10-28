"""Load the packaged Windows Rust library and enumerate ports via its C API."""
import ctypes
import json
import os
from pathlib import Path
import sys
import time

library_path = Path(sys.argv[1]).resolve()
with os.add_dll_directory(str(library_path.parent)):
    library = ctypes.CDLL(str(library_path))
    library.lightbar_create.restype = ctypes.c_void_p
    library.lightbar_send.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    library.lightbar_send.restype = ctypes.c_int32
    library.lightbar_next_event.argtypes = [ctypes.c_void_p]
    library.lightbar_next_event.restype = ctypes.c_void_p
    library.lightbar_free_string.argtypes = [ctypes.c_void_p]
    library.lightbar_destroy.argtypes = [ctypes.c_void_p]

    controller = library.lightbar_create()
    if not controller:
        raise RuntimeError('Windows core did not create a controller')
    try:
        if library.lightbar_send(controller, b'{"type":"refresh_ports"}') != 0:
            raise RuntimeError('Windows core rejected the refresh request')
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            pointer = library.lightbar_next_event(controller)
            if not pointer:
                time.sleep(0.05)
                continue
            try:
                event = json.loads(ctypes.string_at(pointer).decode('utf-8'))
            finally:
                library.lightbar_free_string(pointer)
            if event.get('type') == 'error':
                raise RuntimeError(event.get('message', 'Windows core reported an error'))
            if event.get('type') == 'ports':
                if not isinstance(event.get('ports'), list):
                    raise RuntimeError('Windows core returned an invalid port list')
                print('Packaged Windows core loaded and enumerated serial ports.')
                break
        else:
            raise RuntimeError('Windows core did not return a port list')
    finally:
        library.lightbar_destroy(controller)
