"""PDS build directory for a firmware image: copies project/ and replaces the RAM INIT files.

Usage: python make_app_build.py <image_dir> <build_dir>
Then build it: powershell -File pds_build.ps1 -Dir <build_dir>
"""
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ram_init

PROJECT = Path(__file__).resolve().parents[1] / 'project'
img, bd = Path(sys.argv[1]), Path(sys.argv[2])
if bd.exists():
    raise SystemExit(f'{bd} exists, refusing to overwrite')
shutil.copytree(PROJECT, bd)
itcm = [int(x, 16) for x in (img / 'itcm.hex').read_text().split()]
dtcm = [int(x, 16) for x in (img / 'dtcm.hex').read_text().split()]
assert len(itcm) == 16384 and len(dtcm) == 8192
for bank in (0, 1):
    name = f'soc_itcm_ram_b{bank}'
    (bd / 'ip' / name / 'rtl' / f'{name}_init_param.v').write_text(ram_init.encode_init(itcm[bank::2]), encoding='ascii')
(bd / 'ip/soc_dtcm_ram/rtl/soc_dtcm_ram_init_param.v').write_text(ram_init.encode_init(dtcm), encoding='ascii')
print(f'build dir ready: {bd}')
