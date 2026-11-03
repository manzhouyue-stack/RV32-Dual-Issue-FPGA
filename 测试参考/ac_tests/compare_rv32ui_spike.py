"""Compare every official RV32UI retirement with a Spike commit log.

Run prepare_rv32ui.py on Ubuntu, then copy its *.spike.log files into
tests/rv32ui-spike. This script runs RTL and checks PC, instruction,
register writes and architectural memory accesses through tohost.
"""

from pathlib import Path
from hashlib import sha256
import json
import re
import subprocess
import sys
import tempfile
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--b-core', action='store_true', help='verify B v0.3 handshake core')
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
tests = root / "tests"
images = tests / "rv32ui-bin"
references = tests / "rv32ui-spike"
manifest = json.loads((images / "manifest.json").read_text())

for item in manifest:
    if "image_sha256" in item:
        words = [int(line, 16) for line in
                 (images / f"{item['name']}.mem").read_text().splitlines()]
        payload = b"".join(word.to_bytes(4, "little") for word in words)
        if sha256(payload).hexdigest() != item["image_sha256"]:
            raise SystemExit(f"{item['name']}: RTL image differs from Spike image")

commit_re = re.compile(r"^core\s+0:\s+3\s+(0x[0-9a-f]+)\s+\((0x[0-9a-f]+)\)(.*)$")
reg_re = re.compile(r"\bx(\d+)\s+(0x[0-9a-f]+)")
mem_re = re.compile(r"\bmem\s+(0x[0-9a-f]+)(?:\s+(0x[0-9a-f]+))?")


def spike_trace(path, tohost):
    result = []
    for line in path.read_text().splitlines():
        match = commit_re.match(line)
        if not match:
            continue
        pc, instr = (int(match.group(i), 16) for i in (1, 2))
        if pc < 0x80001000:
            continue
        details = match.group(3)
        reg = reg_re.search(details)
        mem = mem_re.search(details)
        item = (
            pc, instr,
            (int(reg.group(1)), int(reg.group(2), 16)) if reg else None,
            (int(mem.group(1), 16),
             int(mem.group(2), 16) if mem.group(2) else None) if mem else None,
        )
        result.append(item)
        if item[3] and item[3][0] == tohost and item[3][1] is not None:
            break
    return result


def rtl_trace(path):
    result = []
    for line in path.read_text().splitlines():
        fields = line.split()
        pc, instr = int(fields[0], 16), int(fields[1], 16)
        reg = (int(fields[3]), int(fields[4], 16)) if fields[2] == "1" else None
        memory = None
        if fields[5] == "1":
            address = int(fields[7], 16)
            store = int(fields[8], 16) if fields[6] == "1" else None
            if store is not None:
                width = 8 << ((instr >> 12) & 7)
                store = (store >> (8 * (address & 3))) & ((1 << width) - 1)
            memory = (address, store)
        result.append((pc, instr, reg, memory))
    return result


missing = [item["name"] for item in manifest
           if not (references / f"{item['name']}.spike.log").exists()]
if missing:
    raise SystemExit(
        "Missing Spike reference logs for " + ", ".join(missing) +
        ". Generate with prepare_rv32ui.py on Ubuntu and copy into " + str(references)
    )

rtl = [root / "rtl/rv32_pkg.sv", *sorted(
    p for p in (root / "rtl").glob("*.sv") if p.name != "rv32_pkg.sv")]
with tempfile.TemporaryDirectory() as temp:
    exe = Path(temp) / "tb_rv32ui.vvp"
    top = 'tb_b_rv32ui' if args.b_core else 'tb_rv32ui'
    extra = [tests / 'b_protocol_memory.sv'] if args.b_core else []
    subprocess.run(["iverilog", "-g2012", '-I', str(tests), "-s", top, "-o", str(exe),
                    *map(str, rtl), *map(str, extra), str(tests / (top + '.sv'))],
                   check=True, stderr=subprocess.DEVNULL)
    for item in manifest:
        name = item["name"]
        trace = Path(temp) / f"{name}.rtl.trace"
        command = ["vvp", str(exe), f"+mem={images / (name + '.mem')}",
                   f"+tohost={item['tohost']}", f"+words={item['words']}",
                   f"+trace={trace}"]
        subprocess.run(command, check=True, capture_output=True, text=True)
        expected = spike_trace(references / f"{name}.spike.log",
                               int(item["tohost"], 16))
        actual = rtl_trace(trace)
        if len(expected) != len(actual):
            raise SystemExit(f"{name}: commit count Spike={len(expected)} RTL={len(actual)}")
        for index, (want, got) in enumerate(zip(expected, actual)):
            # Spike records the original narrow Store value; RTL stores a
            # replicated word plus byte mask. Compare the addressed bytes.
            if want[3] and want[3][1] is not None:
                width = 8 << ((want[1] >> 12) & 7)
                want = (*want[:3], (want[3][0], want[3][1] & ((1 << width) - 1)))
            if want != got:
                raise SystemExit(f"{name}: commit {index}\nSpike {want}\nRTL   {got}")
        print(f"{name}: {len(actual)} commits match Spike")

print(f"{len(manifest)}/{len(manifest)} RV32UI traces match Spike" + (' (B-core)' if args.b_core else ''))
