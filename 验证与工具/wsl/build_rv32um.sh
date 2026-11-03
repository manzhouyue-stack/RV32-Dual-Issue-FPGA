#!/usr/bin/env bash
# Build official riscv-tests rv32um programs (self-checking via tohost) with
# A's CSR-free test environment, in the same image format as rv32ui-bin.
set -euo pipefail
TC=/opt/riscv32/bin
ENV=/mnt/c/Users/zct03/Desktop/FPGA/AC_to_B_C_START_v0.2_CPUv0.4_2026-10-25/tests/rvtest_env
OUT=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/isa/rv32um-bin
cd ~
[ -d riscv-tests ] || git clone --depth 1 https://github.com/riscv-software-src/riscv-tests.git
mkdir -p "$OUT"
echo "[" > "$OUT/manifest.json"
first=1
for t in ~/riscv-tests/isa/rv32um/*.S; do
    n=$(basename "$t" .S)
    $TC/riscv32-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostdlib -Wl,--no-relax \
        -I"$ENV" -I ~/riscv-tests/isa/macros/scalar -Wl,-Ttext=0x80001000 "$t" -o /tmp/$n.elf
    $TC/riscv32-unknown-elf-objcopy -O binary /tmp/$n.elf /tmp/$n.bin
    tohost=$($TC/riscv32-unknown-elf-nm /tmp/$n.elf | awk '$3=="tohost"{print $1}')
    python3 - "$n" "$tohost" "$OUT" <<'PY'
import struct, sys, pathlib
n, tohost, out = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
data = pathlib.Path(f"/tmp/{n}.bin").read_bytes()
data += b"\0" * (-len(data) % 4)
words = [w for (w,) in struct.iter_unpack("<I", data)]
(out / f"{n}.mem").write_text("\n".join(f"{w:08x}" for w in words) + "\n")
print(f'{n} {tohost} {len(words)}')
PY
done | while read n th w; do
    [ $first = 1 ] || echo "," >> "$OUT/manifest.json"; first=0
    printf '  {"name": "%s", "tohost": "%s", "words": %s}' "$n" "$th" "$w" >> "$OUT/manifest.json"
done
echo "" >> "$OUT/manifest.json"; echo "]" >> "$OUT/manifest.json"
ls "$OUT"
