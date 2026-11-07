"""Mapped primitives per module instance from a hierarchical PDS synthesis netlist.

Usage: python count_hier_res.py <soc_stage1_top_syn.vm> [depth]
Counts are synthesis level (before place and route), inclusive of sub-instances.
"""
import collections
import re
import sys

text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
depth = int(sys.argv[2]) if len(sys.argv) > 2 else 3
modules = {}
for m in re.finditer(r'^\s*module\s+\\?(\S+?)\s*[#(](.*?)^\s*endmodule', text, re.M | re.S):
    modules[m.group(1)] = m.group(2)
inst_re = re.compile(r'^(?:\(\*.*?\*\)\s*)?\s*\\?([A-Za-z_][\w$.\[\]]*)\s+(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?\\?([^\s(]+)\s*\(\s*$', re.M)
own = {}
kids = {}
for name, body in modules.items():
    c, k = collections.Counter(), []
    for kind, pat in (('LUT', r'GTP_LUT\w*\s'), ('FF', r'GTP_DFF\w*\s'), ('DRM', r'GTP_DRM\w*\s'),
                      ('APM', r'GTP_APM\w*\s'), ('RAMLUT', r'GTP_RAM\w*\s')):
        c[kind] = len(re.findall(pat, body))
    for m in inst_re.finditer(body):
        if m.group(1) in modules:
            k.append((m.group(2), m.group(1)))
    own[name], kids[name] = c, k


def total(name):
    c = collections.Counter(own[name])
    for _, ref in kids[name]:
        c += total(ref)
    return c


def show(name, inst, level):
    c = total(name)
    print(f"{'  ' * level}{inst} [{name}] LUT={c['LUT']} FF={c['FF']} DRM={c['DRM']} APM={c['APM']} RAM={c['RAMLUT']}")
    if level < depth:
        for i, ref in sorted(kids[name], key=lambda x: -total(x[1])['LUT']):
            if total(ref)['LUT'] >= 20 or total(ref)['DRM']:
                show(ref, i, level + 1)


top = next(n for n in modules if 'top' in n and n not in {r for k in kids.values() for _, r in k})
show(top, 'top', 0)
