"""Run all prepared official rv32ui programs on the stage-one RTL core."""

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--b-core', action='store_true')
args = parser.parse_args()

root = Path(__file__).resolve().parent.parent
images = root / "tests/rv32ui-bin"
manifest = json.loads((images / "manifest.json").read_text())
rtl = [root / "rtl/rv32_pkg.sv", *sorted(
    p for p in (root / "rtl").glob("*.sv") if p.name != "rv32_pkg.sv")]
exe = Path(tempfile.gettempdir()) / "tb_rv32ui.vvp"
top = 'tb_b_rv32ui' if args.b_core else 'tb_rv32ui'
extra = [root / 'tests/b_protocol_memory.sv'] if args.b_core else []
subprocess.run(["iverilog", "-g2012", '-I', str(root / 'tests'), "-s", top, "-o", exe,
                *rtl, *extra, root / ('tests/' + top + '.sv')], check=True)

failed = []
with tempfile.TemporaryDirectory() as trace_dir:
    for item in manifest:
        traces = []
        for inject in (0, 1):
            trace = Path(trace_dir) / f"{item['name']}.{inject}.trace"
            command = ["vvp", str(exe), f"+mem={images / (item['name'] + '.mem')}",
                       f"+tohost={item['tohost']}", f"+words={item['words']}",
                       f"+inject={inject}", f"+trace={trace}"]
            run = subprocess.run(command, cwd=root, text=True, capture_output=True)
            output = run.stdout.strip().splitlines()
            result = output[0] if output else run.stderr.strip()
            if run.returncode or not result.startswith("PASS"):
                failed.append((item["name"], run.stdout, run.stderr))
            traces.append(trace.read_text() if trace.exists() else "")
        if traces[0] != traces[1]:
            failed.append((item["name"], "baseline and injected retire traces differ", ""))
        print(f"{item['name']}: {'PASS baseline/injected trace match' if not any(f[0] == item['name'] for f in failed) else 'FAIL'}")

print(f"{len(manifest) - len({f[0] for f in failed})}/{len(manifest)} RV32UI tests passed with random freezes and trace comparison")
if failed:
    for name, stdout, stderr in failed:
        print(f"\n{name}\n{stdout}{stderr}", file=sys.stderr)
    raise SystemExit(1)
