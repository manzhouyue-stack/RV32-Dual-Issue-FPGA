"""Pipeline efficiency from a Fabric Debugger VCD export of the v11_coremark_debug01 core.

Usage: python analyze_ila.py <capture.vcd> <label> <func_start_hex> <func_end_hex> [out_dir]
One sample = one clk_sys cycle, whatever timescale the VCD header says. w_valid per
lane stands in for retirement. Only samples whose retire_pc lies in the function
count towards its IPC.
"""
import re
import sys
from pathlib import Path

path, label = Path(sys.argv[1]), sys.argv[2]
lo, hi = int(sys.argv[3], 16), int(sys.argv[4], 16)
out = Path(sys.argv[5]) if len(sys.argv) > 5 else path.parent

names = {}
state = {}
rows = []
started = False
for line in path.read_text(errors='replace').splitlines():
    line = line.strip()
    m = re.match(r'\$var wire \d+ (\S+) (\S+) \$end', line)
    if m:
        names[m.group(1)] = m.group(2)
        continue
    if re.fullmatch(r'#\d+', line):
        if started:
            rows.append(dict(state))
        started = True
        continue
    if not started:
        continue
    m = re.fullmatch(r'b([01xzXZ]+) (\S+)', line)
    if m and m.group(2) in names:
        v = m.group(1).lower()
        state[names[m.group(2)]] = int(v.replace('x', '0').replace('z', '0'), 2)
    elif line[:1] in '01' and line[1:] in names:
        state[names[line[1:]]] = int(line[0])
if started:
    rows.append(dict(state))
assert rows, 'no samples parsed'

RET0, RET1 = 'system/cpu/retire_pc', 'system/cpu/retire1_pc'
W0, W1 = 'system/cpu/w_valid[0]', 'system/cpu/w_valid[1]'


def stats(samples, title):
    n = len(samples)
    if not n:
        print(f'  {title}: no samples')
        return
    w0 = sum(s[W0] for s in samples)
    w1 = sum(s[W1] for s in samples)
    both = sum(s[W0] and s[W1] for s in samples)
    none = sum(not s[W0] and not s[W1] for s in samples)
    red = sum(s['system/cpu/redirect'] for s in samples)
    print(f'  {title}: cycles={n} retired={w0 + w1} IPC={(w0 + w1) / n:.3f} '
          f'both={100 * both / n:.1f}% one={100 * (n - both - none) / n:.1f}% none={100 * none / n:.1f}% '
          f'redirects={red} e_fire={100 * sum(s["system/cpu/e_fire"] for s in samples) / n:.1f}% '
          f'load={100 * sum(s["system/ld_valid"] for s in samples) / n:.1f}% '
          f'store={100 * sum(s["system/st_valid"] for s in samples) / n:.1f}%')


trig = next((i for i, s in enumerate(rows) if lo == s[RET0] or lo == s[RET1]), None)
inside = [s for s in rows if lo <= s[RET0] < hi]
print(f'{label}: samples={len(rows)} first_entry_sample={trig} '
      f'pc_range=0x{min(s[RET0] for s in rows):x}..0x{max(s[RET0] for s in rows):x}')
stats(rows, 'whole capture')
stats(inside, f'inside 0x{lo:x}..0x{hi:x}')
try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    plot = ['w_valid[0]', 'w_valid[1]', 'm_valid[0]', 'm_valid[1]', 'e_valid[0]', 'e_valid[1]',
            'd_fire0', 'd_fire1', 'e_fire', 'redirect']
    keys = ['system/cpu/' + p for p in plot] + ['system/ld_valid', 'system/st_valid']
    start = trig or 0
    span = rows[start:start + 120]
    fig, ax = plt.subplots(figsize=(11, 4.4))
    for row, key in enumerate(reversed(keys)):
        ax.step(range(start, start + len(span)), [row + 0.75 * s[key] for s in span], where='post', linewidth=1, color='#1f4e79')
    ax.set_yticks([i + 0.35 for i in range(len(keys))], [k.split('/')[-1] for k in reversed(keys)], fontsize=8)
    ax.set_xlabel('clk_sys cycle (sample index)')
    ax.set_title(f'CoreMark {label}: 120 cycles from function entry')
    fig.tight_layout()
    fig.savefig(out / f'ila_{label}.png', dpi=160)
    print(f'  figure: {out / f"ila_{label}.png"}')
except ImportError:
    print('  matplotlib not installed, no figure')
