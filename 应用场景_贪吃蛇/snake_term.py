"""Terminal client for the RISC-V snake console (Windows).

Usage: python snake_term.py COM5 [log_file]
Shows the board's ANSI output in this console and sends raw keys (arrows map to
w/a/s/d). Ctrl+C exits. Every received byte goes to the log as board evidence.
"""
import ctypes
import datetime
import msvcrt
import sys
import threading

import serial

ARROWS = {b'H': b'w', b'P': b's', b'M': b'd', b'K': b'a'}


def enable_ansi():
    kernel = ctypes.windll.kernel32
    out = kernel.GetStdHandle(-11)
    mode = ctypes.c_uint32()
    kernel.GetConsoleMode(out, ctypes.byref(mode))
    kernel.SetConsoleMode(out, mode.value | 0x0004)


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else 'COM5'
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    path = sys.argv[2] if len(sys.argv) > 2 else f'snake_{stamp}.log'
    enable_ansi()
    ser = serial.Serial(port, 115200, timeout=0.05)
    print(f'{port} open, log: {path}\nPress KEY0 on the board to start. Ctrl+C exits.', flush=True)
    stop = threading.Event()

    def reader():
        with open(path, 'wb') as log:
            while not stop.is_set():
                data = ser.read(4096)
                if data:
                    log.write(data)
                    log.flush()
                    sys.stdout.buffer.write(data)
                    sys.stdout.buffer.flush()

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    try:
        while True:
            ch = msvcrt.getch()
            if ch == b'\x03':
                break
            if ch in (b'\x00', b'\xe0'):
                ch = ARROWS.get(msvcrt.getch(), b'')
            if ch:
                ser.write(ch)
    except KeyboardInterrupt:
        pass
    stop.set()
    thread.join(1)
    ser.close()
    sys.stdout.write('\x1b[?25h\x1b[0m\n')
    print(f'log saved: {path}')


if __name__ == '__main__':
    main()
