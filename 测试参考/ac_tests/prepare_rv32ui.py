"""Build stage-one applicable official rv32ui programs on the Ubuntu VM.

Requires ~/src/riscv-tests-master and tests/rvtest_env/riscv_test.h copied to
isa/macros/scalar/riscv_test.h. Produces .mem files and manifest.json.
"""

from pathlib import Path
from hashlib import sha256
import json
import re
import struct
import subprocess

home = Path.home()
source = home / "src/riscv-tests-master"
output = home / "rv32ui-build"
output.mkdir(exist_ok=True)
gcc = home / "bin/riscv32-unknown-elf-gcc"
spike = home / "bin/spike"
objcopy = home / "opt/riscv/usr/bin/riscv64-unknown-elf-objcopy"
nm = home / "opt/riscv/usr/bin/riscv64-unknown-elf-nm"
skip = {"ma_data"}
manifest = []

for test in sorted((source / "isa/rv32ui").glob("*.S")):
    name = test.stem
    if name in skip:
        continue
    elf = output / f"{name}.elf"
    binary = output / f"{name}.bin"
    subprocess.run(
        [gcc, "-nostdlib", "-Wl,--no-relax", f"-I{source / 'isa/macros/scalar'}",
         "-Wl,-Ttext=0x80001000", test, "-o", elf],
        check=True,
    )
    isa = "rv32i_zifencei" if name == "fence_i" else "rv32i"
    spike_run = subprocess.run(
        [spike, f"--isa={isa}", "-l", "--log-commits", elf],
        capture_output=True, text=True, timeout=20,
    )
    if spike_run.returncode:
        raise RuntimeError(f"Spike failed for {name}: {spike_run.stderr}")
    (output / f"{name}.spike.log").write_text(spike_run.stderr)
    subprocess.run([objcopy, "-O", "binary", elf, binary], check=True)
    symbols = subprocess.check_output([nm, elf], text=True)
    match = re.search(r"^([0-9a-f]+) D tohost$", symbols, re.MULTILINE)
    if not match:
        raise RuntimeError(f"missing tohost: {name}")
    payload = binary.read_bytes()
    payload += bytes((-len(payload)) % 4)
    words = [value for (value,) in struct.iter_unpack("<I", payload)]
    (output / f"{name}.mem").write_text("\n".join(f"{word:08x}" for word in words) + "\n")
    manifest.append({"name": name, "tohost": match.group(1),
                     "words": len(words), "image_sha256": sha256(payload).hexdigest()})

(output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Prepared {len(manifest)} Spike-passing RV32UI programs in {output}")
