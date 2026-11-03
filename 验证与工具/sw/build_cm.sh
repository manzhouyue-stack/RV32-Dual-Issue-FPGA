#!/usr/bin/env bash
# Build one CoreMark image set inside WSL and publish itcm.hex/dtcm.hex.
# Usage: build_cm.sh <name> <mode:performance|validation> <iterations> "<opt flags>" [hz]
set -euo pipefail
NAME=$1; MODE=$2; ITER=$3; OPT=$4; HZ=${5:-50000000}; MARCH=${6:-rv32i}; ITCMKB=${7:-32}
SW=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/sw/coremark
OUT=/mnt/c/Users/zct03/Desktop/FPGA/opt_v05/images/$NAME
TC=/opt/riscv32/bin
rm -rf "$OUT/build" && mkdir -p "$OUT/build"
python3 "$SW/build.py" --mode "$MODE" --iterations "$ITER" --opt="$OPT" --hz "$HZ" --march "$MARCH" --itcm-kb "$ITCMKB" \
    --cc $TC/riscv32-unknown-elf-gcc --objdump $TC/riscv32-unknown-elf-objdump --out-dir "$OUT/build"
cp "$OUT/build/itcm_full.mem" "$OUT/itcm.hex"
cp "$OUT/build/dtcm.mem" "$OUT/dtcm.hex"
$TC/riscv32-unknown-elf-size "$OUT/build/firmware.elf" | tail -1
