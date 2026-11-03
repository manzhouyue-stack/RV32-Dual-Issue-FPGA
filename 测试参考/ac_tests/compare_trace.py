"""Compare stage-one RTL retire records with Spike commit records."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
SPIKE = ROOT / "rv32i_trace.spike.log"
RTL = ROOT / "rv32i_trace.rtl.log"
START = 0x80001000
TOHOST = 0x80002080

commit_re = re.compile(r"^core\s+0:\s+3\s+(0x[0-9a-f]+)\s+\((0x[0-9a-f]+)\)(.*)$")
reg_re = re.compile(r"\bx(\d+)\s+(0x[0-9a-f]+)")
mem_re = re.compile(r"\bmem\s+(0x[0-9a-f]+)(?:\s+(0x[0-9a-f]+))?")


def spike_commits():
    out = []
    for line in SPIKE.read_text().splitlines():
        match = commit_re.match(line)
        if not match:
            continue
        pc, instr = (int(match.group(i), 16) for i in (1, 2))
        if pc < START:
            continue
        details = match.group(3)
        reg = reg_re.search(details)
        mem = mem_re.search(details)
        out.append({
            "pc": pc,
            "instr": instr,
            "rd": int(reg.group(1)) if reg else None,
            "data": int(reg.group(2), 16) if reg else None,
            "mem_addr": int(mem.group(1), 16) if mem else None,
            "store_data": int(mem.group(2), 16) if mem and mem.group(2) else None,
        })
        if out[-1]["mem_addr"] == TOHOST and out[-1]["store_data"] is not None:
            break
    return out


def rtl_commits():
    out = []
    for line in RTL.read_text().splitlines():
        pc, instr, rd_we, rd, data, mem_valid, mem_we, mem_addr, store_data, _be = line.split()
        out.append({
            "pc": int(pc, 16),
            "instr": int(instr, 16),
            "rd": int(rd) if rd_we == "1" else None,
            "data": int(data, 16) if rd_we == "1" else None,
            "mem_addr": int(mem_addr, 16) if mem_valid == "1" else None,
            "store_data": int(store_data, 16) if mem_we == "1" else None,
        })
    return out


expected, actual = spike_commits(), rtl_commits()
if len(expected) != len(actual):
    raise SystemExit(f"commit count differs: Spike={len(expected)} RTL={len(actual)}")
for index, (reference, observed) in enumerate(zip(expected, actual)):
    if reference != observed:
        raise SystemExit(
            f"first mismatch at commit {index}:\nSpike {reference}\nRTL   {observed}"
        )
print(f"PASS: {len(actual)} RV32I commits match Spike (PC, instruction, rd, value, memory)")
