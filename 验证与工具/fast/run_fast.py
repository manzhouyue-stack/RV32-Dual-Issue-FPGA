"""Fast CoreMark run: python run_fast.py <cpu_dir> <image_dir> [--stats] [--trace]

<image_dir> holds itcm.hex/dtcm.hex (8192 words each). Prints the CoreMark
transcript summary, timed-window cycles and CRC lines.
"""
from pathlib import Path
import argparse, hashlib, os, re, subprocess, sys, time

HERE = Path(__file__).resolve().parent
OPT = HERE.parent
VIV = Path("C:/Xilinx/Vivado/2021.1/bin")
ap = argparse.ArgumentParser()
ap.add_argument("cpu")
ap.add_argument("images")
ap.add_argument("--stats", action="store_true")
ap.add_argument("--trace", action="store_true")
ap.add_argument("--trace-cyc", action="store_true", help="retire trace with cycle column")
ap.add_argument("--m", action="store_true", help="ENABLE_M=1 (cpu_v07+)")
ap.add_argument("--b", action="store_true", help="ENABLE_B=1 (cpu_v08+)")
ap.add_argument("--hz", type=int, default=50000000, help="SYS_CLK_HZ (cpu_v07+ wrapper)")
ap.add_argument("--uart", action="store_true", help="real uart_transport + baud check bench (tb_uart)")
ap.add_argument("--ip", default=None, help="vendor RAM IP dir (INIT inside) instead of behavioral RAM")
ap.add_argument("--limit", type=int, default=400_000_000)
ap.add_argument("--raw", action="store_true", help="print the whole simulator output")
a = ap.parse_args()

cpu = OPT / a.cpu
img = Path(a.images).resolve()
defs = (["CPU_STATS"] if a.stats else []) + (["CPU_TRACE"] if a.trace or a.trace_cyc else []) + (["CPU_TRACE_CYC"] if a.trace_cyc else []) + (["CPU_M"] if a.m else []) + (["CPU_B"] if a.b else [])
defs += [f"SYS_CLK_HZ={a.hz}"] if a.hz != 50000000 else []
key = a.cpu + "_" + "_".join(d.replace("=", "") for d in defs) + ("_ip" if a.ip else "") + ("_uart" if a.uart else "")
work = HERE / "work" / key
work.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, PROCESSOR_ARCHITECTURE="AMD64")
soc = OPT / "soc" / "source"
# SoC sources: the newest soc_vNN at or below the CPU version overrides B's files.
socdirs = [d for d in ("soc_v11", "soc_v10", "soc_v09", "soc_v08", "soc_v07", "soc_v05")
           if a.cpu != "cpu_v04" and a.cpu >= "cpu_" + d[4:]]


def soc_file(name):
    for d in socdirs:
        if (OPT / d / name).exists():
            return OPT / d / name
    return soc / name


wrapper = soc_file("soc_stage1_core.sv")
dual = a.cpu >= "cpu_v09"
src = [cpu / "rv32_pkg.sv"] + sorted(p for p in cpu.glob("*.sv") if p.name != "rv32_pkg.sv")
banked = a.cpu >= "cpu_v08"
src += [soc_file(n) for n in ("tcm_subsystem.sv", "mem_io_subsystem.v", "fifo16x8.v",
                              "cycle_counter64.v", "mmio_regs.v")]
ddr = a.cpu >= "cpu_v11"
if ddr:
    src += [OPT / "soc_v11" / n for n in ("sdp_ram.sv", "ddr_bridge.sv", "icache.sv", "dcache.sv", "ddr_cache_top.sv")]
    src += [HERE / "ddr_axi_model.sv"]
PANGO = Path("C:/pango/PDS_2023.2-SP3-ads/arch/vendor/pango/verilog/simulation")
if a.ip:
    ipd = Path(a.ip).resolve()
    ram = [PANGO / "GTP_GRS.v", PANGO / "GTP_DRM36K_E1.v"]
    banks = ("itcm_ram_b0", "itcm_ram_b1", "dtcm_ram") if banked else ("itcm_ram", "dtcm_ram")
    for b in banks:
        ram += [ipd / f"soc_{b}" / f"soc_{b}.v", ipd / f"soc_{b}" / "rtl" / f"ipm2l_dpram_v1_10_soc_{b}.v"]
    incs = sum((["-i", str(ipd / f"soc_{b}" / "rtl")] for b in banks), [])
else:
    ram, incs = [HERE / "fast_ram.v"], []
top = "tb_uart" if a.uart else "tb_fast"
src += ram + [wrapper, soc / "uart_transport.v" if a.uart else HERE / "fast_uart.v", HERE / f"{top}.sv"]
stamp = hashlib.sha256(b"".join(p.read_bytes() for p in src) + key.encode()).hexdigest()


def run(tool, args, cwd=work):
    r = subprocess.run([str(VIV / f"{tool}.bat"), *args], cwd=cwd, env=env, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout[-3000:], r.stderr[-1500:])
        raise SystemExit(f"{tool} failed")
    return r.stdout


if not (work / "stamp").exists() or (work / "stamp").read_text() != stamp:
    opts = ["-sv", "-d", "RV32_SIM_CHECKS"] + (["-d", "CPU_DUAL"] if dual else []) + (["-d", "CPU_DDR"] if ddr else []) + sum((["-d", d] for d in defs), []) + incs + (["-d", "FAST_VENDOR_RAM"] if a.ip else [])
    # cmd.exe splits batch arguments at '=', so xvlog options go through -f.
    (work / "xvlog.f").write_text("\n".join(f'"{x}"' if "=" in x else x
                                            for x in opts + [str(p).replace("\\", "/") for p in src]) + "\n")
    run("xvlog", ["-f", "xvlog.f"])
    run("xelab", [top, "-s", "fast", "-timescale", "1ns/1ps"])
    (work / "stamp").write_text(stamp)

extra = ""
if banked:
    # 64 KiB ITCM as even/odd word banks; pad smaller images with zeros.
    w = (img / "itcm.hex").read_text().split()
    w += ["00000000"] * (16384 - len(w))
    (work / "itcm0.hex").write_text("\n".join(w[0::2]) + "\n")
    (work / "itcm1.hex").write_text("\n".join(w[1::2]) + "\n")
    extra = (f'-testplusarg "ITCM0_HEX={(work / "itcm0.hex").as_posix()}"\n'
             f'-testplusarg "ITCM1_HEX={(work / "itcm1.hex").as_posix()}"\n')
(work / "opts.txt").write_text(extra +
    f'-testplusarg "ITCM_HEX={(img / "itcm.hex").as_posix()}"\n'
    f'-testplusarg "DTCM_HEX={(img / "dtcm.hex").as_posix()}"\n'
    f'-testplusarg "LIMIT={a.limit}"\n')
t0 = time.time()
out = run("xsim", ["fast", "-R", "-f", "opts.txt"])
wall = time.time() - t0
text = out[out.find("CM_BUILD"):] if "CM_BUILD" in out else out
keep = [l for l in text.splitlines() if re.match(
    r"(CM_BUILD|2K |CoreMark Size|Total ticks|Iterations|Compiler|seedcrc|\[0\]crc|Correct|Errors|ERROR|CM_TICKS|FAST_|Total time)", l)]
print(out if a.raw else "\n".join(keep))
if a.trace or a.trace_cyc:
    print("trace:", (work / "retire_trace.txt"))
print(f"wall={wall:.0f}s")
if a.uart:
    print("\n".join(l for l in out.splitlines() if "UART_CHECK" in l))
    sys.exit(0 if "UART_CHECK line=" in out else 1)
if "FAST_DONE" not in out or "Error:" in out:
    print(out[-2000:])
    sys.exit(1)
