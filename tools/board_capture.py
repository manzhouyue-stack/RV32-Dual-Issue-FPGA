"""Raw UART capture as board evidence.

Usage: python board_capture.py <name> <seconds> [COM5]
Saves <name>_<time>.bin and a sidecar .json with the byte count and SHA256.
Start this first, then press KEY0 so the log begins at the first boot line.
"""
import datetime
import hashlib
import json
import sys
import time
from pathlib import Path

import serial

name, seconds = sys.argv[1], float(sys.argv[2])
port = sys.argv[3] if len(sys.argv) > 3 else 'COM5'
stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
out = Path.cwd() / f'{name}_{stamp}.bin'
raw = bytearray()
with serial.Serial(port, 115200, timeout=0.1) as ser:
    ser.reset_input_buffer()
    print(f'READY on {port}: press KEY0 now, capturing {seconds:.0f} s', flush=True)
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        data = ser.read(4096)
        if data:
            raw += data
            sys.stdout.write(data.decode('ascii', 'replace'))
            sys.stdout.flush()
out.write_bytes(raw)
out.with_suffix('.json').write_text(json.dumps({
    'name': name, 'port': port, 'seconds': seconds, 'bytes': len(raw),
    'sha256': hashlib.sha256(raw).hexdigest(), 'captured_at': stamp}, indent=2))
print(f'\nsaved {out} ({len(raw)} bytes)')
