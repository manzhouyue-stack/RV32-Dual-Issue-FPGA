"""Assemble a PDS build directory for the v1.1 SoC (dual-issue core, Zicsr/traps,
I/D caches + DDR3 via the Pango ips2l_hmic_s controller).

Usage: python make_build_v11.py <build_dir> <ram_ip_dir> <sys_clk_hz>
Constraints = B's CPU/board FDC (+100 MHz clk_sys) + the vendor DDR3 example's
active pin attributes for mem_*/ref_clk_* and its controller clock constraints,
with the CPU clocks declared asynchronous to the DDR clocks (all crossings go
through ddr_bridge's toggle handshake).
"""
import re
import shutil
import sys
from pathlib import Path

OPT = Path(r'C:\Users\zct03\Desktop\FPGA\opt_v05')
DDR = OPT / 'ref/ddr3_test/2_9_ddr3_test/2_9_ddr3_test/ddr3_test/ipcore/ddr3_test'
bd, ramip, hz = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
if bd.exists():
    shutil.rmtree(bd)
(bd / 'source' / 'cpu').mkdir(parents=True)
(bd / 'ip').mkdir()

cpu = ['rv32_pkg.sv', 'rv32_alu.sv', 'rv32_decode.sv', 'rv32_imm.sv', 'rv32_bitmanip.sv',
       'rv32_dslot.sv', 'rv32_regfile2.sv', 'rv32_csr.sv', 'rv32_core_d.sv']
for f in cpu:
    shutil.copy(OPT / 'cpu_v11' / f, bd / 'source' / 'cpu' / f)
soc11 = ['tcm_subsystem.sv', 'mem_io_subsystem.v', 'cycle_counter64.v', 'mmio_regs.v', 'sdp_ram.sv',
         'ddr_bridge.sv', 'icache.sv', 'dcache.sv', 'ddr_cache_top.sv', 'soc_stage1_top.sv']
for f in soc11:
    shutil.copy(OPT / 'soc_v11' / f, bd / 'source' / f)
w = (OPT / 'soc_v11' / 'soc_stage1_core.sv').read_text(encoding='utf-8')
(bd / 'source' / 'soc_stage1_core.sv').write_text(
    w.replace('`define SYS_CLK_HZ 50000000', f'`define SYS_CLK_HZ {hz}'), encoding='utf-8')
for f in ('clk_rst_gen.v', 'fifo16x8.v', 'uart_transport.v'):
    shutil.copy(OPT / 'soc' / 'source' / f, bd / 'source' / f)
for b in ('soc_itcm_ram_b0', 'soc_itcm_ram_b1', 'soc_dtcm_ram'):
    shutil.copytree(ramip / b, bd / 'ip' / b)
shutil.copytree(OPT / ('ip100' if hz == 100_000_000 else 'soc/ip') / 'pll_27_to_50', bd / 'ip' / 'pll_27_to_50')

# DDR3 controller IP sources, in the vendor project's order.
ddr_dst = bd / 'ip' / 'ddr3_test'
ddr_dst.mkdir()
for item in ('ddr3_test.v', 'ddr3_test_ddrphy_top.v', 'ddr3_test.idf', 'rtl'):
    src = DDR / item
    (shutil.copytree if src.is_dir() else shutil.copy)(src, ddr_dst / item if src.is_dir() else ddr_dst)
vendor_pds = (DDR / 'pnr' / 'ddr3_test.pds').read_text(encoding='utf-8', errors='replace')
ddr_files = [f'ip/ddr3_test/{m[3:]}' for m in re.findall(r'_file "(\.\./(?:rtl/[^"]+|ddr3_test[^"/]*\.v))"', vendor_pds)]
assert ddr_files and all((bd / f).exists() for f in ddr_files), 'missing DDR IP files'

# ---- constraints
fdc = (OPT / 'soc' / 'soc_stage1.fdc').read_text(encoding='utf-8')
fdc = fdc.replace('-name {clk_50m}', '-name {clk_sys}')
fdc = fdc.replace('-multiply_by {50} -divide_by {27}', '-multiply_by {100} -divide_by {27}' if hz == 100_000_000
                  else '-multiply_by {50} -divide_by {27}')
board = (DDR / 'pnr' / 'ddr_test.fdc').read_text(encoding='utf-8', errors='replace').splitlines()
ddr_pins, ddr_timing = [], []
for line in board:
    t = line.strip()
    if t.startswith('define_attribute') and re.search(r'\{p:(mem_|ref_clk_)', t):
        ddr_pins.append(t)
    elif t.startswith(('create_clock', 'create_generated_clock', 'set_multicycle_path',
                       'set_clock_uncertainty', 'set_clock_groups')) and 'free_clk' not in t:
        ddr_timing.append(t)
fdc += ('\n# ---- DDR3 (vendor ips2l_hmic_s example for MES2L676-100HP: pins and controller clocks)\n'
        + '\n'.join(ddr_pins) + '\n' + '\n'.join(ddr_timing) + '\n'
        '# CPU clocks are asynchronous to every DDR clock; crossings use ddr_bridge.\n'
        'set_clock_groups -name cpu_clks -asynchronous -group [get_clocks {clk_27m clk_sys}]\n')
(bd / 'soc_stage1.fdc').write_text(fdc, encoding='utf-8')

# ---- project file
design = [f'source/cpu/{f}' for f in cpu] + [f'source/{f}' for f in (
    'clk_rst_gen.v', 'tcm_subsystem.sv', 'fifo16x8.v', 'uart_transport.v', 'cycle_counter64.v',
    'mmio_regs.v', 'sdp_ram.sv', 'ddr_bridge.sv', 'icache.sv', 'dcache.sv', 'ddr_cache_top.sv', 'mem_io_subsystem.v',
    'soc_stage1_core.sv', 'soc_stage1_top.sv')]
for b in ('soc_itcm_ram_b0', 'soc_itcm_ram_b1'):
    design += [f'ip/{b}/{b}.v', f'ip/{b}/rtl/ipm2l_dpram_v1_10_{b}.v']
design += ddr_files
entry = '''                (_file "{}"
                    (_format verilog)
                    (_timespec "2026-10-29T11:58:45")
                    (_library "work")
                )
'''
pds = (OPT / 'build_v07m' / 'soc_stage1.pds').read_text(encoding='utf-8')
pds = re.sub(r'(\(_widget wgt_my_design_src\s*\(_input\n).*?(\n            \)\n        \)\n        \(_widget wgt_my_ips_src)',
             lambda m: m.group(1) + ''.join(entry.format(f) for f in design).rstrip('\n') + m.group(2),
             pds, count=1, flags=re.S)
pds = re.sub(r'\s*\(_ip "ip/soc_itcm_ram/soc_itcm_ram\.idf".*?\(_library "soc_itcm_ram"\)\n\s*\)', '', pds, count=1, flags=re.S)
# As the vendor DDR3 project: route priority for the PHY DQ clock-gate nets
# (ddr3_test.rcf) and multi-corner / hold-fixing place & route.
shutil.copy(DDR / 'pnr' / 'ddr3_test.rcf', bd / 'ddr3_test.rcf')
rcf_in = '''        (_widget wgt_edit_route_cons
            (_attribute _click_to_run (_switch ON))
            (_input
                (_file "ddr3_test.rcf"
                    (_format rcf)
                    (_timespec "2024-06-14T11:33:18")
                )
            )
        )'''
pds, n = re.subn(r'        \(_widget wgt_edit_route_cons\n            \(_attribute _click_to_run \(_switch ON\)\)\n        \)',
                 rcf_in, pds, count=1)
assert n == 1, 'route constraint widget not found'
pds, n = re.subn(r'(\(_command cmd_pnr\n\s*\(_gci_state \(_integer \d+\)\)\n)',
                 r'\1            (_option optimize_multi_corner_timing (_switch ON))\n'
                 r'            (_option fix_hold_violation (_switch ON))\n', pds, count=1)
assert n == 1, 'cmd_pnr not found'


def drop_command(text, name):
    """Remove one balanced '(_command <name> ...)' block."""
    i = text.index(f'(_command {name}\n')
    depth, j = 0, i
    while True:
        if text[j] == '(':
            depth += 1
        elif text[j] == ')':
            depth -= 1
            if depth == 0:
                break
        j += 1
    k = text.rfind('\n', 0, i)
    return text[:k] + text[j + 1:]


# Use the vendor flow's unified pnr (its hold fixing) instead of place/route/route_optimize.
for c in ('cmd_place', 'cmd_route_optimize', 'cmd_route'):
    pds = drop_command(pds, c)
assert '(_command cmd_pnr' in pds and '(_command cmd_place' not in pds
assert 'soc_itcm_ram.idf' not in pds and 'rv32_core_d.sv' in pds and 'ddr3_test.v' in pds
(bd / 'soc_stage1.pds').write_text(pds, encoding='utf-8')
print(f'build dir ready: {bd} ({len(design)} design files, {len(ddr_pins)} DDR pin attributes, '
      f'{len(ddr_timing)} DDR timing constraints)')
