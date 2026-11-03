#!/usr/bin/env bash
# Build the snake console for the v1.1 SoC and publish itcm.hex/dtcm.hex.
# Usage: build.sh [sim]   "sim" = short ticks, 921600 baud, k/q test keys.
set -euo pipefail
HERE=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/sw/snake
CM=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/sw/coremark
TC=/opt/riscv32/bin
if [ "${1:-}" = sim ]; then
    OUT=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/images/snake_sim
    DEFS=(-DSNAKE_SIM '-DUART_NCO_50MHZ_115200=UINT32_C(2473904)')
else
    OUT=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/images/snake
    DEFS=('-DUART_NCO_50MHZ_115200=UINT32_C(309238)')
fi
mkdir -p "$OUT/build"
sed -e 's/LENGTH = 28K/LENGTH = 60K/' \
    -e 's/\*(\.text \.text\.\*)/*(.text .text.*) . = ALIGN(4); __ap_start = .; KEEP(*(.ap_text)) . = ALIGN(4); __ap_end = .;/' \
    "$CM/link.ld" > "$OUT/build/link.ld"
grep -q __ap_start "$OUT/build/link.ld"
$TC/riscv32-unknown-elf-gcc -march=rv32im_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32 -O2 -g -ffreestanding "${DEFS[@]}" \
    -fno-builtin -fno-jump-tables -fno-tree-loop-distribute-patterns -Wall -Wextra \
    -nostdlib -nostartfiles -msmall-data-limit=0 -mno-relax -Wl,--no-relax \
    -I"$CM" -I"$HERE" -T "$OUT/build/link.ld" -Wl,-Map,"$OUT/build/snake.map" \
    "$CM/boot.S" "$CM/start.S" "$HERE/../irqtest/trap.S" "$HERE/autopilot.c" "$HERE/snake.c" -lgcc -o "$OUT/build/snake.elf"
$TC/riscv32-unknown-elf-objdump -d "$OUT/build/snake.elf" > "$OUT/build/snake.disasm"
$TC/riscv32-unknown-elf-size "$OUT/build/snake.elf"
python3 - "$OUT" <<'PY'
import struct, sys, pathlib
out = pathlib.Path(sys.argv[1]); elf = (out / 'build/snake.elf').read_bytes()
phoff, = struct.unpack_from('<I', elf, 28); phentsize, phnum = struct.unpack_from('<HH', elf, 42)
itcm, dtcm = bytearray(65536), bytearray(32768)
for i in range(phnum):
    kind, off, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from('<8I', elf, phoff + i * phentsize)
    if kind != 1 or not filesz: continue
    img, base = (itcm, 0) if paddr < 0x10000 else (dtcm, 0x10000)
    img[paddr - base:paddr - base + filesz] = elf[off:off + filesz]
for name, img in (('itcm.hex', itcm), ('dtcm.hex', dtcm)):
    (out / name).write_text(''.join(f'{w:08x}\n' for w, in struct.iter_unpack('<I', img)))
print('snake images written to', out)
PY
