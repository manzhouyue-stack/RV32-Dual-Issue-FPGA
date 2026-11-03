"""Run the snake console simulation against the frozen v1.1 sources.

Usage: python run_snake.py   (images from opt_v05/images/snake_sim, see sw/snake/build.sh sim)
"""
from pathlib import Path
import os, re, subprocess, sys, time

HERE = Path(__file__).resolve().parent
OPT = HERE.parent
FROZEN = OPT.parent / 'V10_V11_REPAIR_HANDOFF_20261102/V10_V11_REPAIR_HANDOFF_20261102/01_VALIDATED_V11/systest/source'
VIV = Path('C:/Xilinx/Vivado/2021.1/bin')
img = OPT / 'images/snake_sim'
work = HERE / 'work/snake'
work.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, PROCESSOR_ARCHITECTURE='AMD64')

cpu = FROZEN / 'cpu'
src = [cpu / 'rv32_pkg.sv'] + sorted(p for p in cpu.glob('*.sv') if p.name != 'rv32_pkg.sv')
src += [FROZEN / n for n in ('tcm_subsystem.sv', 'mem_io_subsystem.v', 'fifo16x8.v', 'cycle_counter64.v', 'mmio_regs.v',
                             'sdp_ram.sv', 'ddr_bridge.sv', 'icache.sv', 'dcache.sv', 'ddr_cache_top.sv',
                             'soc_stage1_core.sv', 'uart_transport.v')]
src += [HERE / 'ddr_axi_model.sv', HERE / 'fast_ram.v', HERE / 'tb_snake.sv']


def run(tool, args):
    r = subprocess.run([str(VIV / f'{tool}.bat'), *args], cwd=work, env=env, capture_output=True, text=True, errors='replace')
    if r.returncode:
        print(r.stdout[-4000:], r.stderr[-1500:])
        raise SystemExit(f'{tool} failed')
    return r.stdout


opts = ['-sv', '-d', 'RV32_SIM_CHECKS', '-d', 'CPU_DUAL', '-d', 'CPU_DDR', '-d', 'CPU_M', '-d', 'CPU_B']
(work / 'xvlog.f').write_text('\n'.join(opts + [p.as_posix() for p in src]) + '\n')
run('xvlog', ['-f', 'xvlog.f'])
run('xelab', ['tb_snake', '-s', 'snake', '-timescale', '1ns/1ps'])
w = (img / 'itcm.hex').read_text().split()
w += ['00000000'] * (16384 - len(w))
(work / 'itcm0.hex').write_text('\n'.join(w[0::2]) + '\n')
(work / 'itcm1.hex').write_text('\n'.join(w[1::2]) + '\n')
(work / 'opts.txt').write_text(
    f'-testplusarg "ITCM0_HEX={(work / "itcm0.hex").as_posix()}"\n'
    f'-testplusarg "ITCM1_HEX={(work / "itcm1.hex").as_posix()}"\n'
    f'-testplusarg "ITCM_HEX={(img / "itcm.hex").as_posix()}"\n'
    f'-testplusarg "DTCM_HEX={(img / "dtcm.hex").as_posix()}"\n')
t0 = time.time()
out = run('xsim', ['snake', '-R', '-f', 'opts.txt'])
print('\n'.join(l for l in out.splitlines() if l.startswith(('KEY', 'BOOT', 'SNAKE_', 'Error', 'ERROR'))))
print(f'wall={time.time() - t0:.0f}s log={work / "snake_tx.log"}')
# PASS must also prove the autopilot ran from DDR and the replayed game scored.
tx = (work / 'snake_tx.log').read_text(errors='replace')
m = re.search(r'SIM_STATS.*score=(\d+).*ichits=(\d+)', tx)
print(m.group(0) if m else 'no SIM_STATS')
ok = 'SNAKE_PASS' in out and m and int(m.group(1)) > 0 and int(m.group(2)) > 0
print('CHECK', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
