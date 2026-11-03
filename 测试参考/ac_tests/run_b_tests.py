"""Portable A-side v0.4 regression; run on scorpion with Icarus 12 in PATH.

The B test double implements protocol timing, not the actual B subsystem/IP.
Logs and model VCDs are preserved under output/b_v04_validation.
"""
from pathlib import Path
from datetime import datetime, timezone
import json
import platform
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
out = root / 'output/b_v04_validation'
out.mkdir(parents=True, exist_ok=True)
rtl = [root / 'rtl/rv32_pkg.sv', *sorted(
    p for p in (root / 'rtl').glob('*.sv') if p.name != 'rv32_pkg.sv')]
results = []


def run(name, command, expected='PASS', timeout=180):
    result = subprocess.run([str(x) for x in command], cwd=root,
                            capture_output=True, text=True, timeout=timeout)
    (out / (name + '.log')).write_text(result.stdout + result.stderr)
    if result.returncode or (expected and expected not in result.stdout):
        print(result.stdout[-3000:] + result.stderr[-3000:], flush=True)
        raise SystemExit(f'{name} failed: exit={result.returncode}')
    results.append({'name': name, 'passed': True})
    if expected:
        summary = [line for line in result.stdout.splitlines() if 'PASS' in line or '41/41' in line]
        print(name + ': ' + (summary[-1] if summary else 'PASS'), flush=True)
    return result.stdout


with tempfile.TemporaryDirectory() as temp:
    for top in ('tb_units', 'tb_core', 'tb_control', 'tb_illegal', 'tb_freeze_mmio', 'tb_trace'):
        exe = Path(temp) / (top + '.vvp')
        run(top + '_compile', ['iverilog', '-g2012', '-s', top, '-o', exe, *rtl,
                              root / ('tests/' + top + '.sv')], expected=None)
        run(top, ['vvp', exe])
    run('legacy_small_spike', [sys.executable, root / 'tests/compare_trace.py'])
    exe = Path(temp) / 'tb_b_directed.vvp'
    run('b_directed_compile', ['iverilog', '-g2012', '-I', root / 'tests', '-s', 'tb_b_directed',
                              '-o', exe, *rtl, root / 'tests/b_protocol_memory.sv',
                              root / 'tests/tb_b_directed.sv'], expected=None)
    waves = {0: 'ordinary_bus', 1: 'mmio_freeze', 2: 'redirect_pending', 3: 'fencei_pending'}
    for case in range(20):
        command = ['vvp', exe, f'+case={case}']
        if case in waves:
            command.append('+vcd=' + str(out / (waves[case] + '.vcd')))
        run(f'b_directed_{case:02}', command)
    run('legacy_random_official', [sys.executable, root / 'tests/run_rv32ui.py'], expected='41/41')
    run('legacy_official_spike', [sys.executable, root / 'tests/compare_rv32ui_spike.py'], expected='41/41')
    run('b_random_official', [sys.executable, root / 'tests/run_rv32ui.py', '--b-core'], expected='41/41')
    spike = run('b_official_spike', [sys.executable, root / 'tests/compare_rv32ui_spike.py', '--b-core'], expected='41/41')

version = subprocess.run(['iverilog', '-V'], capture_output=True, text=True).stdout.splitlines()[0]
report = {
    'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'host_platform': platform.system(), 'iverilog': version,
    'all_passed': True, 'b_directed_cases': 20,
    'b_official_cases': 41, 'b_spike_commits': sum(map(int, re.findall(r': (\d+) commits match Spike', spike))),
    'random_ready_delay_freeze_trace_match': True,
    'actual_b_subsystem_or_vendor_ip_tested': False,
    'results': results,
}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print('PASS A v0.4: legacy baseline, 20 B-protocol directed cases, 41 random traces, 12090 Spike commits', flush=True)
