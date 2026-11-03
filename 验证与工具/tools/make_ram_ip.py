"""Create ITCM/DTCM RAM IP copies whose INIT holds a given image set.

Usage: python make_ram_ip.py <image_dir> <out_ip_dir>
Uses B's accepted encoder (tools/soc/ram_init.py, 4 banks x 2 lanes x 18-bit).
First proves the encoder reproduces the current perf1 IP INIT byte for byte.
"""
import importlib.util
import shutil
import sys
from pathlib import Path

OPT = Path(r'C:\Users\zct03\Desktop\FPGA\opt_v05')
B_TOOL = Path(r'C:\Users\zct03\Documents\ChatGPT\FPGA\tools\soc\ram_init.py')
spec = importlib.util.spec_from_file_location('ram_init', B_TOOL)
ram_init = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ram_init)


def words(path):
    w = [int(x, 16) for x in Path(path).read_text().split()]
    assert len(w) == 8192, (path, len(w))
    return w


def param_file(ipdir, bank):
    return Path(ipdir) / f'soc_{bank}_ram' / 'rtl' / f'soc_{bank}_ram_init_param.v'


# Self-check against the IP B built and verified for soc_cm_perf1.
for bank in ('itcm', 'dtcm'):
    ref = param_file(OPT / 'soc' / 'ip', bank).read_text().replace('\r\n', '\n')
    got = ram_init.encode_init(words(OPT / 'images' / 'perf1' / f'{bank}.hex'))
    if ref.strip() != got.strip():
        raise SystemExit(f'encoder self-check failed for {bank}')

img, out = Path(sys.argv[1]), Path(sys.argv[2])
for bank in ('itcm', 'dtcm'):
    dst = out / f'soc_{bank}_ram'
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(OPT / 'soc' / 'ip' / f'soc_{bank}_ram', dst)
    param_file(out, bank).write_text(ram_init.encode_init(words(img / f'{bank}.hex')), encoding='ascii')
print(f'encoder self-check OK; wrote {out}')
