"""Split an ELF into the ITCM (64 KiB) and DTCM (32 KiB) word images.

Usage: elf2hex.py <file.elf> <out_dir>
"""
import pathlib
import struct
import sys

elf = pathlib.Path(sys.argv[1]).read_bytes()
out = pathlib.Path(sys.argv[2])
phoff, = struct.unpack_from('<I', elf, 28)
phentsize, phnum = struct.unpack_from('<HH', elf, 42)
itcm, dtcm = bytearray(65536), bytearray(32768)
for i in range(phnum):
    kind, off, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from('<8I', elf, phoff + i * phentsize)
    if kind != 1 or not filesz:
        continue
    img, base = (itcm, 0) if paddr < 0x10000 else (dtcm, 0x10000)
    img[paddr - base:paddr - base + filesz] = elf[off:off + filesz]
for name, img in (('itcm.hex', itcm), ('dtcm.hex', dtcm)):
    (out / name).write_text(''.join(f'{w:08x}\n' for w, in struct.iter_unpack('<I', img)))
