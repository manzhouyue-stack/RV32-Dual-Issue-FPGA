#!/usr/bin/env bash
# Build one firmware image into firmware/images/<name>/ (itcm.hex, dtcm.hex).
# Usage: build.sh perf | val | perf1 | snake | snake_sim | systest
# RISCV_BIN = directory holding riscv32-unknown-elf-gcc (default /opt/riscv32/bin).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TC=${RISCV_BIN:-/opt/riscv32/bin}
NAME=${1:?target}
OUT=$HERE/images/$NAME
mkdir -p "$OUT/build"
CC=$TC/riscv32-unknown-elf-gcc
CM=$HERE/coremark
CM_OPT="-O3 -mtune=sifive-7-series -funroll-all-loops -finline-limit=1000"
NCO_115200='-DUART_NCO_50MHZ_115200=UINT32_C(309238)'

coremark() {   # mode iterations
    python3 "$CM/build.py" --mode "$1" --iterations "$2" --opt="$CM_OPT" --hz 100000000 \
        --march rv32im_zba_zbb_zbs --itcm-kb 64 --cc "$CC" \
        --objdump "$TC/riscv32-unknown-elf-objdump" --out-dir "$OUT/build"
    cp "$OUT/build/itcm_full.mem" "$OUT/itcm.hex"
    cp "$OUT/build/dtcm.mem" "$OUT/dtcm.hex"
}

bare() {   # elf name, extra link edit, then compiler arguments
    local elf=$1 sed_extra=$2; shift 2
    sed -e 's/LENGTH = 28K/LENGTH = 60K/' $sed_extra "$CM/link.ld" > "$OUT/build/link.ld"
    "$CC" -march=rv32im_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32 -O2 -g -ffreestanding \
        -fno-builtin -nostdlib -nostartfiles -msmall-data-limit=0 -mno-relax -Wl,--no-relax \
        -I"$CM" -T "$OUT/build/link.ld" -Wl,-Map,"$OUT/build/$elf.map" \
        "$CM/boot.S" "$CM/start.S" "$@" -lgcc -o "$OUT/build/$elf.elf"
    "$TC/riscv32-unknown-elf-objdump" -d "$OUT/build/$elf.elf" > "$OUT/build/$elf.disasm"
    python3 "$HERE/elf2hex.py" "$OUT/build/$elf.elf" "$OUT"
}

snake() {   # extra flags
    sed -e 's/LENGTH = 28K/LENGTH = 60K/' \
        -e 's/\*(\.text \.text\.\*)/*(.text .text.*) . = ALIGN(4); __ap_start = .; KEEP(*(.ap_text)) . = ALIGN(4); __ap_end = .;/' \
        "$CM/link.ld" > "$OUT/build/link.ld"
    "$CC" -march=rv32im_zicsr_zifencei_zba_zbb_zbs -mabi=ilp32 -O2 -g -ffreestanding "$@" \
        -fno-builtin -fno-jump-tables -fno-tree-loop-distribute-patterns -Wall -Wextra \
        -nostdlib -nostartfiles -msmall-data-limit=0 -mno-relax -Wl,--no-relax \
        -I"$CM" -I"$HERE/snake" -T "$OUT/build/link.ld" -Wl,-Map,"$OUT/build/snake.map" \
        "$CM/boot.S" "$CM/start.S" "$HERE/irqtest/trap.S" "$HERE/snake/autopilot.c" "$HERE/snake/snake.c" \
        -lgcc -o "$OUT/build/snake.elf"
    "$TC/riscv32-unknown-elf-objdump" -d "$OUT/build/snake.elf" > "$OUT/build/snake.disasm"
    python3 "$HERE/elf2hex.py" "$OUT/build/snake.elf" "$OUT"
}

case "$NAME" in
    perf) coremark performance 7000 ;;
    val) coremark validation 7000 ;;
    perf1) coremark performance 1 ;;
    snake) snake "$NCO_115200" ;;
    snake_sim) snake -DSNAKE_SIM '-DUART_NCO_50MHZ_115200=UINT32_C(2473904)' ;;
    systest) bare systest "" "$NCO_115200" -DSYSTEST "$HERE/ddrtest/kernel.S" "$HERE/ddrtest/ddrtest.c" \
        "$HERE/irqtest/trap.S" "$HERE/irqtest/irqtest.c" "$HERE/systest/systest.c" ;;
    *) echo "unknown target $NAME" >&2; exit 2 ;;
esac
echo "images written to $OUT"
