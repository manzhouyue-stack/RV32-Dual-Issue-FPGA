"""Build directory for a new firmware on the frozen v1.1 hardware: copies the validated
project unchanged and replaces only the three RAM INIT files.

Usage: python make_build_app.py <image_dir> <build_dir>
"""
import filecmp
import importlib.util
import shutil
import sys
from pathlib import Path

FROZEN = Path(r'C:\Users\zct03\Desktop\FPGA\V10_V11_REPAIR_HANDOFF_20261102\V10_V11_REPAIR_HANDOFF_20261102'
              r'\01_VALIDATED_V11\systest')
spec = importlib.util.spec_from_file_location('ram_init', r'C:\Users\zct03\Documents\ChatGPT\FPGA\tools\soc\ram_init.py')
ram_init = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ram_init)

img, bd = Path(sys.argv[1]), Path(sys.argv[2])
if bd.exists():
    raise SystemExit(f'{bd} exists, refusing to overwrite')
bd.mkdir(parents=True)
for item in ('source', 'ip'):
    shutil.copytree(FROZEN / item, bd / item)
for item in ('soc_stage1.fdc', 'soc_stage1.pds', 'ddr3_test.rcf'):
    shutil.copy(FROZEN / item, bd / item)

itcm = [int(x, 16) for x in (img / 'itcm.hex').read_text().split()]
dtcm = [int(x, 16) for x in (img / 'dtcm.hex').read_text().split()]
assert len(itcm) == 16384 and len(dtcm) == 8192
for bank in (0, 1):
    name = f'soc_itcm_ram_b{bank}'
    (bd / 'ip' / name / 'rtl' / f'{name}_init_param.v').write_text(ram_init.encode_init(itcm[bank::2]), encoding='ascii')
(bd / 'ip' / 'soc_dtcm_ram' / 'rtl' / 'soc_dtcm_ram_init_param.v').write_text(ram_init.encode_init(dtcm), encoding='ascii')

# Everything except the INIT files must stay byte-identical to the frozen project.
diff = filecmp.dircmp(FROZEN / 'source', bd / 'source')
assert not diff.diff_files and not filecmp.dircmp(FROZEN / 'source' / 'cpu', bd / 'source' / 'cpu').diff_files
print(f'build dir ready: {bd}')
