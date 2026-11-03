"""Derive a 100 MHz version of B's 27->50 MHz GPLL IP (same module/instance
names so clk_rst_gen and the FDC paths stay unchanged).

Original: FDIV 31.25 (31+2/8), ODIV0 16.875 (16+7/8): VCO 843.75, out 50 MHz.
New:      FDIV 37.5  (37+4/8), ODIV0 10.125 (10+1/8): VCO 1012.5, out 100 MHz.
Both use only the documented n/8 fractional steps (UG041001)."""
import re
import shutil
from pathlib import Path

opt = Path(r'C:\Users\zct03\Desktop\FPGA\opt_v05')
src = opt / 'soc' / 'ip' / 'pll_27_to_50'
dst = opt / 'ip100' / 'pll_27_to_50'
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(src, dst)

v = (dst / 'pll_27_to_50.v').read_text(encoding='utf-8')
for name, old, new in [('STATIC_RATIO0', '16.875', '10.125'), ('STATIC_RATIOF', '31.25', '37.5'),
                       ('STATIC_DUTY0', '16', '10'), ('STATIC_DUTYF', '31', '37')]:
    pat = re.compile(r'(localparam\s+(?:real|integer)\s+' + name + r'\s*=\s*)' + re.escape(old) + ';')
    v, n = pat.subn(r'\g<1>' + new + ';', v)
    assert n == 1, name
(dst / 'pll_27_to_50.v').write_text(v, encoding='utf-8')

x = (dst / 'pll_27_to_50.idf').read_text(encoding='utf-8')
for name, old, new in [('STATIC_RATIO0', '16.875', '10.125'), ('STATIC_DUTY0', '16', '10'),
                       ('STATIC_RATIO0_advancedPage', '16', '10'), ('STATIC_FRAC0_advancedPage', '7', '1'),
                       ('STATIC_RATIO7', '31.25', '37.5'), ('STATIC_DUTY7', '31', '37'),
                       ('STATIC_RATIO7_advancedPage', '31', '37'), ('STATIC_FRAC7_advancedPage', '2', '4'),
                       ('CLKOUT0_REQ_FREQ_basicPage', '50.00000000', '100.00000000')]:
    pat = re.compile(r'(<name>' + name + r'</name>\s*<value>)' + re.escape(old) + '(</value>)')
    x, n = pat.subn(r'\g<1>' + new + r'\g<2>', x)
    assert n == 1, name
(dst / 'pll_27_to_50.idf').write_text(x, encoding='utf-8')
print('ip100/pll_27_to_50 written')
