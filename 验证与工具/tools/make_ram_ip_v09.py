"""v0.9 RAM IPs: 64 KiB ITCM as two 8192x32 banks (even / odd words) plus DTCM.

Usage: python make_ram_ip_v09.py <image_dir> <out_ip_dir>
Each ITCM bank is a renamed copy of B's soc_itcm_ram IP (module names and the
INIT include file get a _b0/_b1 suffix) with INIT from B's accepted encoder.
"""
import importlib.util
import re
import shutil
import sys
from pathlib import Path

OPT = Path(r'C:\Users\zct03\Desktop\FPGA\opt_v05')
spec = importlib.util.spec_from_file_location('ram_init', r'C:\Users\zct03\Documents\ChatGPT\FPGA\tools\soc\ram_init.py')
ram_init = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ram_init)

img, out = Path(sys.argv[1]), Path(sys.argv[2])
itcm = [int(x, 16) for x in (img / 'itcm.hex').read_text().split()]
itcm += [0] * (16384 - len(itcm))
dtcm = [int(x, 16) for x in (img / 'dtcm.hex').read_text().split()]
assert len(itcm) == 16384 and len(dtcm) == 8192
src = OPT / 'soc' / 'ip' / 'soc_itcm_ram'
for bank in (0, 1):
    name = f'soc_itcm_ram_b{bank}'
    dst = out / name
    if dst.exists():
        shutil.rmtree(dst)
    (dst / 'rtl').mkdir(parents=True)
    top = (src / 'soc_itcm_ram.v').read_text(encoding='utf-8')
    core = (src / 'rtl' / 'ipm2l_dpram_v1_10_soc_itcm_ram.v').read_text(encoding='utf-8')
    top = re.sub(r'\bipm2l_dpram_v1_10_soc_itcm_ram\b', f'ipm2l_dpram_v1_10_{name}', top)
    top = re.sub(r'\bsoc_itcm_ram\b', name, top)
    core = re.sub(r'\bipm2l_dpram_v1_10_soc_itcm_ram\b', f'ipm2l_dpram_v1_10_{name}', core)
    core = core.replace('soc_itcm_ram_init_param.v', f'{name}_init_param.v')
    assert f'{name}_init_param.v' in core
    (dst / f'{name}.v').write_text(top, encoding='utf-8')
    (dst / 'rtl' / f'ipm2l_dpram_v1_10_{name}.v').write_text(core, encoding='utf-8')
    (dst / 'rtl' / f'{name}_init_param.v').write_text(ram_init.encode_init(itcm[bank::2]), encoding='ascii')
d = out / 'soc_dtcm_ram'
if d.exists():
    shutil.rmtree(d)
shutil.copytree(OPT / 'soc' / 'ip' / 'soc_dtcm_ram', d)
(d / 'rtl' / 'soc_dtcm_ram_init_param.v').write_text(ram_init.encode_init(dtcm), encoding='ascii')
print(f'wrote {out}: soc_itcm_ram_b0, soc_itcm_ram_b1, soc_dtcm_ram')
