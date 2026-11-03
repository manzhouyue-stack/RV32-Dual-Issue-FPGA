"""Per-algorithm pipeline efficiency from a cycle-stamped retire trace.

Usage: python ipc_by_func.py <retire_trace.txt> <nm_output.txt>
Stall cycles before a retirement are charged to the function that retires.
"""
import bisect
import collections
import sys

syms = sorted((int(l.split()[0], 16), l.split()[2]) for l in open(sys.argv[2]) if len(l.split()) == 3 and l.split()[1] in 'tT')
addrs = [a for a, _ in syms]
GROUP = {'core_list_': 'list', 'cmp_': 'list', 'calc_func': 'list', 'crc': 'crc', 'matrix_': 'matrix', 'core_bench_matrix': 'matrix',
         'core_state': 'state', 'core_bench_state': 'state', 'core_bench_list': 'list', 'iterate': 'other'}


def group(name):
    for k, v in GROUP.items():
        if name.startswith(k):
            return v
    return 'other'


ins = collections.Counter()
cyc = collections.Counter()
dual = collections.Counter()
fn_ins = collections.Counter()
fn_cyc = collections.Counter()
start = None
prev_c = None
for line in open(sys.argv[1]):
    pc, _, c = line.split()
    pc, c = int(pc, 16), int(c)
    name = syms[bisect.bisect_right(addrs, pc) - 1][1]
    if start is None:
        if not name.startswith('core_bench_list'):
            continue
        start = c
        prev_c = c
    g = group(name)
    ins[g] += 1
    fn_ins[name] += 1
    if c == prev_c:
        dual[g] += ins[g] > 1 and 1
    d = c - prev_c
    cyc[g] += d
    fn_cyc[name] += d
    prev_c = c
print(f"{'group':8}{'instrs':>12}{'cycles':>12}{'IPC':>8}{'share':>8}")
tot = sum(cyc.values())
for g, n in sorted(ins.items(), key=lambda x: -cyc[x[0]]):
    print(f'{g:8}{n:12d}{cyc[g]:12d}{n / max(cyc[g], 1):8.3f}{100 * cyc[g] / tot:7.1f}%')
print(f"{'total':8}{sum(ins.values()):12d}{tot:12d}{sum(ins.values()) / tot:8.3f}")
print('top functions:')
for name, n in fn_cyc.most_common(14):
    print(f'  {name:28}{fn_ins[name]:10d}{n:10d}{fn_ins[name] / max(n, 1):8.3f}')
