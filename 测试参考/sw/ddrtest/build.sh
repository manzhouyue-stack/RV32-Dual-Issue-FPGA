#!/usr/bin/env bash
# Build irqtest for the v1.0 SoC (64 KiB banked ITCM) and publish itcm.hex/dtcm.hex.
set -euo pipefail
HERE=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/sw/ddrtest
CM=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/sw/coremark
OUT=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/images/ddrtest
TC=/opt/riscv32/bin
mkdir -p "$OUT/build"
sed 's/LENGTH = 28K/LENGTH = 60K/' "$CM/link.ld" > "$OUT/build/link.ld"
$TC/riscv32-unknown-elf-gcc -march=rv32im_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32 -O2 -g -ffreestanding -DUART_NCO_50MHZ_115200="UINT32_C(309238)" \
    -fno-builtin -nostdlib -nostartfiles -msmall-data-limit=0 -mno-relax -Wl,--no-relax \
    -I"$CM" -T "$OUT/build/link.ld" -Wl,-Map,"$OUT/build/ddrtest.map" \
    "$CM/boot.S" "$CM/start.S" "$HERE/kernel.S" "$HERE/ddrtest.c" -lgcc -o "$OUT/build/ddrtest.elf"
$TC/riscv32-unknown-elf-objdump -d "$OUT/build/ddrtest.elf" > "$OUT/build/ddrtest.disasm"
python3 - "$OUT" <<'PY'
import struct, sys, pathlib
out = pathlib.Path(sys.argv[1]); elf = (out / 'build/ddrtest.elf').read_bytes()
phoff, = struct.unpack_from('<I', elf, 28); phentsize, phnum = struct.unpack_from('<HH', elf, 42)
itcm, dtcm = bytearray(65536), bytearray(32768)
for i in range(phnum):
    kind, off, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from('<8I', elf, phoff + i * phentsize)
    if kind != 1 or not filesz: continue
    img, base = (itcm, 0) if paddr < 0x10000 else (dtcm, 0x10000)
    img[paddr - base:paddr - base + filesz] = elf[off:off + filesz]
for name, img in (('itcm.hex', itcm), ('dtcm.hex', dtcm)):
    (out / name).write_text(''.join(f'{w:08x}\n' for w, in struct.iter_unpack('<I', img)))
print('ddrtest images written')
PY
