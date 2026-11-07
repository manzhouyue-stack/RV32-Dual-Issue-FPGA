"""RTL simulation of the v1.1 SoC with Vivado XSim, DDR model and behavioral RAMs.

Usage: python run_sim.py coremark <image_dir>   CoreMark bench with an instant UART
       python run_sim.py snake <image_dir>      snake bench with the real UART
                                                (firmware/build.sh snake_sim)
XILINX_VIVADO = Vivado directory (default C:/Xilinx/Vivado/2021.1).
"""
from pathlib import Path
import os
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
RTL = HERE.parent / 'project/source'
VIV = Path(os.environ.get('XILINX_VIVADO', 'C:/Xilinx/Vivado/2021.1')) / 'bin'
mode, img = sys.argv[1], Path(sys.argv[2]).resolve()
if mode not in ('coremark', 'snake'):
    raise SystemExit('mode must be coremark or snake')
work = HERE / 'work' / mode
work.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, PROCESSOR_ARCHITECTURE='AMD64')

cpu = RTL / 'cpu'
src = [cpu / 'rv32_pkg.sv'] + sorted(p for p in cpu.glob('*.sv') if p.name != 'rv32_pkg.sv')
src += [RTL / n for n in ('tcm_subsystem.sv', 'mem_io_subsystem.v', 'fifo16x8.v', 'cycle_counter64.v', 'mmio_regs.v',
                          'sdp_ram.sv', 'ddr_bridge.sv', 'icache.sv', 'dcache.sv', 'ddr_cache_top.sv', 'soc_stage1_core.sv')]
src += [HERE / 'ddr_axi_model.sv', HERE / 'fast_ram.v']
if mode == 'snake':
    src += [RTL / 'uart_transport.v', HERE / 'tb_snake.sv']
    top = 'tb_snake'
else:
    src += [HERE / 'fast_uart.v', HERE / 'tb_fast.sv']
    top = 'tb_fast'


def run(tool, args):
    r = subprocess.run([str(VIV / f'{tool}.bat'), *args], cwd=work, env=env, capture_output=True, text=True, errors='replace')
    if r.returncode:
        print(r.stdout[-4000:], r.stderr[-1500:])
        raise SystemExit(f'{tool} failed')
    return r.stdout


opts = ['-sv', '-d', 'RV32_SIM_CHECKS', '-d', 'CPU_DUAL', '-d', 'CPU_DDR', '-d', 'CPU_M', '-d', 'CPU_B']
(work / 'xvlog.f').write_text('\n'.join(opts + [p.as_posix() for p in src]) + '\n')
run('xvlog', ['-f', 'xvlog.f'])
run('xelab', [top, '-s', 'sim', '-timescale', '1ns/1ps'])
words = (img / 'itcm.hex').read_text().split()
(work / 'itcm0.hex').write_text('\n'.join(words[0::2]) + '\n')
(work / 'itcm1.hex').write_text('\n'.join(words[1::2]) + '\n')
(work / 'opts.txt').write_text(
    f'-testplusarg "ITCM0_HEX={(work / "itcm0.hex").as_posix()}"\n'
    f'-testplusarg "ITCM1_HEX={(work / "itcm1.hex").as_posix()}"\n'
    f'-testplusarg "ITCM_HEX={(img / "itcm.hex").as_posix()}"\n'
    f'-testplusarg "DTCM_HEX={(img / "dtcm.hex").as_posix()}"\n'
    f'-testplusarg "LIMIT=400000000"\n')
out = run('xsim', ['sim', '-R', '-f', 'opts.txt'])
if mode == 'coremark':
    print('\n'.join(l for l in out.splitlines() if re.match(r'(CM_BUILD|Total ticks|seedcrc|\[0\]crc|FAST_)', l)))
    sys.exit(0 if 'FAST_DONE' in out else 1)
print('\n'.join(l for l in out.splitlines() if l.startswith(('KEY', 'BOOT', 'SNAKE_'))))
tx = (work / 'snake_tx.log').read_text(errors='replace')
m = re.search(r'SIM_STATS.*score=(\d+).*ichits=(\d+)', tx)
print(m.group(0) if m else 'no SIM_STATS')
# PASS must also prove the autopilot ran from DDR and the replayed game scored.
ok = 'SNAKE_PASS' in out and m and int(m.group(1)) > 0 and int(m.group(2)) > 0
print('CHECK', 'PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
