"""Build CoreMark variants (WSL), run on the fast bench (CRC + trace), and
score each with the dual-issue model. Usage: python sweep_flags.py name:flags ..."""
import re
import shutil
import subprocess
import sys
from pathlib import Path

OPT = Path(r'C:\Users\zct03\Desktop\FPGA\opt_v05')
sys.path.insert(0, str(OPT / 'tools'))
from bp_model import load  # noqa: E402
import dual_model as dm  # noqa: E402

MARCH = 'rv32im_zba_zbb_zbs'
BEST = dict(W=2, late_alu=True, cascade=True, mispredict_gap=2, mem_ports='ldst')
for spec in sys.argv[1:]:
    name, flags = spec.split(':', 1)
    b = subprocess.run(['ssh', 'fpga-wsl', f"bash /mnt/c/Users/zct03/Desktop/FPGA/opt_v05/sw/build_cm.sh "
                        f"{name} performance 1 '{flags}' 50000000 {MARCH} 64"],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if 'PASS build' not in b.stdout:
        print(f'{name}: BUILD FAILED', (b.stdout + b.stderr)[-400:])
        continue
    text = b.stdout.strip().splitlines()[-1].split()[0]
    r = subprocess.run([sys.executable, 'run_fast.py', 'cpu_v08', f'../images/{name}', '--m', '--b', '--trace'],
                       cwd=OPT / 'fast', capture_output=True, text=True)
    crc_ok = all(x in r.stdout for x in ('0xe714', '0x1fd7', '0x8e3a'))
    m = re.search(r'window_cycles=(\d+) window_retired=(\d+)', r.stdout)
    if not m or not crc_ok:
        print(f'{name}: RUN FAILED crc_ok={crc_ok}', r.stdout[-300:])
        continue
    tr = OPT / 'tools' / f'trace_{name}.txt'
    shutil.copy(OPT / 'fast' / 'work' / 'cpu_v08_CPU_TRACE_CPU_M_CPU_B' / 'retire_trace.txt', tr)
    recs = load(tr)
    out = []
    for btb in (6, 8):
        c = dm.simulate(recs, pred=dm.predictions(recs, btb_bits=btb), **BEST)
        out.append(f'BTB{1 << btb}:{1e6 / c:.3f}')
    print(f'{name:10s} flags="{flags}" text={text} single_cycles={m.group(1)} instr={m.group(2)} '
          f'single={1e6 / int(m.group(1)):.3f} dual_model ' + ' '.join(out), flush=True)
