"""Official rv32ui regression for rv32_core_p on XSim, compared with Spike.

Reuses A's images, Spike logs and comparison rules (tests/compare_rv32ui_spike.py)
but compiles once with XSim instead of Icarus. Injection is off: v0.5 relies on
B's fixed one-cycle IF/LD response and unconditional store acceptance.
"""
from pathlib import Path
import json, os, re, subprocess, sys

HERE = Path(__file__).resolve().parent
OPT = HERE.parent
A = OPT.parent / "AC_to_B_C_START_v0.2_CPUv0.4_2026-10-25" / "tests"
VIV = Path("C:/Xilinx/Vivado/2021.1/bin")
args = [a for a in sys.argv[1:] if not a.startswith("--")]
cpu = OPT / (args[0] if args else "cpu_v05")
use_m = "--m" in sys.argv          # build the core with ENABLE_M=1
use_b = "--b" in sys.argv          # build the core with ENABLE_B=1
dual = "--dual" in sys.argv        # rv32_core_d (cpu_v09+): dual fetch model, two retire ports
tb = "tb_d_rv32ui" if dual else "tb_p_rv32ui"
memmodel = "b_protocol_memory2.sv" if dual else "b_protocol_memory.sv"
suite = next((x.split("=", 1)[1] for x in sys.argv if x.startswith("--suite=")), "rv32um" if "--um" in sys.argv else None)
suite_um = suite is not None       # self-checking suites (no Spike log): rv32um, rv32uzb*, ...

src = (A / "compare_rv32ui_spike.py").read_text(encoding="utf-8")
ns = {"re": re}
# Reuse A's spike_trace/rtl_trace definitions verbatim.
exec("commit_re" + src.split("commit_re", 1)[1].split("missing = [")[0], ns)
spike_trace, rtl_trace = ns["spike_trace"], ns["rtl_trace"]

work = HERE / "work"
work.mkdir(exist_ok=True)
env = dict(os.environ, PROCESSOR_ARCHITECTURE="AMD64")
rtl = [cpu / "rv32_pkg.sv"] + sorted(p for p in cpu.glob("*.sv") if p.name != "rv32_pkg.sv")


def run(tool, args):
    r = subprocess.run([str(VIV / f"{tool}.bat"), *args], cwd=work, env=env,
                       capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-2000:])
        raise SystemExit(f"{tool} failed")
    return r.stdout


run("xvlog", ["-sv", "-d", "RV32_SIM_CHECKS", *(["-d", "CPU_M"] if use_m else []), *(["-d", "CPU_B"] if use_b else []), "-i", str(HERE), *map(str, rtl), str(HERE / memmodel),
              str(HERE / f"{tb}.sv")])
run("xelab", [tb, "-s", "isa", "-timescale", "1ns/1ps"])

bins = HERE / f"{suite}-bin" if suite_um else A / "rv32ui-bin"
manifest = json.loads((bins / "manifest.json").read_text())
total_c = total_r = 0
for item in manifest:
    name = item["name"]
    trace = work / f"{name}.trace"
    # cmd.exe splits batch arguments at '=', so plusargs go through -f.
    (work / "opts.txt").write_text("\n".join(f'-testplusarg "{a}"' for a in (
        f"mem={(bins / (name + '.mem')).as_posix()}",
        f"tohost={item['tohost']}", f"words={item['words']}",
        f"trace={trace.as_posix()}")) + "\n")
    out = run("xsim", ["isa", "-R", "-f", "opts.txt"])
    m = re.search(r"PASS [PD]-core rv32ui retired=(\d+) cycles=(\d+)", out)
    if not m or re.search(r"Error:|Fatal", out):
        print(out[-2000:])
        if "--keep-going" in sys.argv:
            print(f"{name}: FAIL", (re.findall(r"(?:Fatal|Error)[^\n]*", out) or [out[-300:]])[-1], flush=True)
            continue
        raise SystemExit(f"{name}: simulation failed")
    if suite_um:
        total_r += int(m.group(1)); total_c += int(m.group(2))
        print(f"{name}: self-check PASS, retired={m.group(1)} cycles={m.group(2)}", flush=True)
        passed = globals().get("passed", 0) + 1
        globals()["passed"] = passed
        continue
    expected = spike_trace(A / "rv32ui-spike" / f"{name}.spike.log", int(item["tohost"], 16))
    actual = rtl_trace(trace)
    if len(expected) != len(actual):
        raise SystemExit(f"{name}: commit count Spike={len(expected)} RTL={len(actual)}")
    for index, (want, got) in enumerate(zip(expected, actual)):
        if want[3] and want[3][1] is not None:
            width = 8 << ((want[1] >> 12) & 7)
            want = (*want[:3], (want[3][0], want[3][1] & ((1 << width) - 1)))
        if want != got:
            raise SystemExit(f"{name}: commit {index}\nSpike {want}\nRTL   {got}")
    total_r += int(m.group(1)); total_c += int(m.group(2))
    print(f"{name}: {len(actual)} commits match Spike, cycles={m.group(2)}", flush=True)

print(f"{globals().get('passed', len(manifest)) if suite_um else len(manifest)}/{len(manifest)} " + (f"{suite} self-checks pass" if suite_um else "RV32UI traces match Spike") +
      f" ({cpu.name}{', ENABLE_M=1' if use_m else ''}{', ENABLE_B=1' if use_b else ''}); "
      f"retired={total_r} cycles={total_c}")
