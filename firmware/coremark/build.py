"""Build fixed RV32I CoreMark or timer smoke images; requires B timer extension."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import subprocess

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=['smoke','performance','validation'], default='smoke')
parser.add_argument('--iterations', type=int, default=1)
parser.add_argument('--cc', default=str(Path.home() / 'bin/riscv32-unknown-elf-gcc'))
parser.add_argument('--objdump', default=str(Path.home() / 'opt/riscv/usr/bin/riscv64-unknown-elf-objdump'))
parser.add_argument('--out-dir', type=Path, default=None)
parser.add_argument('--opt', default='-O2', help='optimization flags replacing -O2, space separated')
parser.add_argument('--march', default='rv32i', help='e.g. rv32i, rv32im, rv32im_zba_zbb_zbs_zicond')
parser.add_argument('--itcm-kb', type=int, default=32, choices=[32, 64])
parser.add_argument('--hz', type=int, default=50000000, help='CPU/timer clock for UART NCO and EXPECTED_HZ')
args = parser.parse_args()
if not 1 <= args.iterations <= 0x7fffffff: parser.error('iterations must be 1..2147483647')
lock=json.loads((here/'upstream-lock.json').read_text())
for name,digest in lock['files'].items():
    if hashlib.sha256((here/'upstream'/name).read_bytes()).hexdigest()!=digest: raise SystemExit('Upstream hash mismatch: '+name)
out = (args.out_dir or here / ('build_' + args.mode)).resolve()
out.mkdir(parents=True, exist_ok=True)
elf = out / 'c_start.elf'
sources = ['platform.c','printf.c'] + (['timer_smoke.c'] if args.mode=='smoke' else ['core_portme.c'])
upstream = [] if args.mode=='smoke' else [str(here/'upstream'/n) for n in ['core_main.c','core_list_join.c','core_matrix.c','core_state.c','core_util.c']]
identity = hashlib.sha256(b''.join(f.read_bytes() for f in sorted(here.iterdir()) if f.name in {*sources,'core_portme.h','timer.h','platform.h','mmio.h','boot.S','start.S','link.ld','build.py'})+json.dumps(lock,sort_keys=True).encode()+str(args.iterations).encode()+args.mode.encode()+args.opt.encode()+str(args.hz).encode()+args.march.encode()+str(args.itcm_kb).encode()).hexdigest()[:16]
opt_flags = args.opt.split()
ITCM_BYTES = args.itcm_kb * 1024
link_script = here / 'link.ld'
if args.itcm_kb != 32:
    # 64 KiB banked ITCM (v0.8 SoC): application region 0x1000-0xFFFF.
    out.mkdir(parents=True, exist_ok=True)
    link_script = out / 'link_itcm64.ld'
    link_script.write_text((here / 'link.ld').read_text().replace('LENGTH = 28K', 'LENGTH = 60K'))
flags_str = ' '.join(['-march=' + args.march, '-mabi=ilp32', *opt_flags, '-msmall-data-limit=0', '-mno-relax', '-fno-delete-null-pointer-checks'])
nco = (16 * 115200 * (1 << 24) + args.hz // 2) // args.hz
command = [args.cc, '-march=' + args.march, '-mabi=ilp32', *opt_flags, '-g', '-Wall', '-Wextra',
           '-ffreestanding', '-fno-delete-null-pointer-checks', '-fno-builtin', '-fno-stack-protector', '-fno-pic',
           '-fno-asynchronous-unwind-tables', '-fno-unwind-tables', '-fstack-usage',
           '-msmall-data-limit=0', '-mno-relax', '-nostdlib', '-nostartfiles',
           '-I'+str(here), '-I'+str(here/'upstream'), '-DITERATIONS='+str(args.iterations),
           '-DVALIDATION_RUN='+str(int(args.mode=='validation')), '-DPERFORMANCE_RUN='+str(int(args.mode!='validation')),
           '-DBUILD_ID="'+identity+'"', '-DCOMPILER_FLAGS="'+flags_str+'"',
           '-DEXPECTED_HZ=UINT32_C('+str(args.hz)+')', '-DUART_NCO_50MHZ_115200=UINT32_C('+str(nco)+')',
           '-Wl,--no-relax', '-Wl,-Map,'+str(out/'c_start.map'), '-T', str(link_script),
           str(here/'boot.S'), str(here/'start.S'), *[str(here/n) for n in sources], *upstream,
           '-lgcc', '-o', str(elf)]
subprocess.run(command, check=True, cwd=out)
disassembly = subprocess.check_output([args.objdump, '-d', str(elf)], text=True)
(out / 'c_start.disasm').write_text(disassembly)
(out / 'firmware.sections.txt').write_text(
    subprocess.check_output([args.objdump, '-h', '-p', str(elf)], text=True))
instructions = []
for line in disassembly.splitlines():
    match = re.match(r'\s*[0-9a-f]+:\s+([0-9a-f]{4,8})\s', line)
    if match:
        word = int(match.group(1), 16)
        if len(match.group(1)) != 8 or word & 0x7f not in {0x03,0x0f,0x13,0x17,0x23,0x33,0x37,0x63,0x67,0x6f}:
            raise SystemExit('Unsupported instruction in final ELF: ' + line)
        if word & 0x7f == 0x33 and word >> 25 == 1 and not args.march.startswith('rv32im'):
            raise SystemExit('M extension in final ELF: ' + line)
        instructions.append(word)
load_kinds = sorted({(word >> 12) & 7 for word in instructions if word & 0x7f == 0x03})
store_kinds = sorted({(word >> 12) & 7 for word in instructions if word & 0x7f == 0x23})
payload = elf.read_bytes()
if payload[:7] != b'\x7fELF\x01\x01\x01':
    raise SystemExit('Expected ELF32 little-endian')
entry, phoff = struct.unpack_from('<II', payload, 24)
phentsize, phnum = struct.unpack_from('<HH', payload, 42)
itcm, dtcm = bytearray(ITCM_BYTES), bytearray(32768)
written = set()
segments = []
for i in range(phnum):
    kind, offset, vaddr, paddr, filesz, memsz, flags, align = struct.unpack_from('<8I', payload, phoff + i * phentsize)
    if kind != 1 or filesz == 0:
        continue
    if paddr < ITCM_BYTES and paddr + filesz <= ITCM_BYTES:
        image, index, region = itcm, paddr, 'ITCM'
    elif 0x10000 <= paddr and paddr + filesz <= 0x18000:
        image, index, region = dtcm, paddr - 0x10000, 'DTCM'
    else:
        raise SystemExit('ELF load segment outside TCM: ' + hex(paddr))
    for n, byte in enumerate(payload[offset:offset + filesz]):
        address = paddr + n
        if address in written:
            raise SystemExit('Overlapping ELF load images')
        written.add(address)
        image[index + n] = byte
    segments.append({'vaddr': hex(vaddr), 'lma': hex(paddr), 'filesz': filesz, 'memsz': memsz, 'region': region})
def save_words(name, image):
    (out / name).write_text(''.join(f'{word:08x}\n' for word, in struct.iter_unpack('<I', image)))
save_words('itcm_full.mem', itcm)
save_words('itcm_app.mem', itcm[0x1000:])
save_words('boot_fixture.mem', itcm[:0x1000])
save_words('dtcm.mem', dtcm)
(out / 'itcm_full.bin').write_bytes(itcm)
(out / 'dtcm.bin').write_bytes(dtcm)
versions = {tool: subprocess.check_output([path, '--version'], text=True).splitlines()[0]
            for tool, path in [('gcc', args.cc), ('objdump', args.objdump)]}
symbols = {}
for line in subprocess.check_output([args.objdump, '-t', str(elf)], text=True).splitlines():
    fields = line.split()
    if len(fields) >= 5 and re.fullmatch('[0-9a-fA-F]{8}', fields[0]):
        symbols[fields[-1]] = '0x' + fields[0]
for source, target in [('c_start.elf','firmware.elf'), ('c_start.map','firmware.map'),
                       ('c_start.disasm','firmware.disasm')]:
    (out / target).write_bytes((out / source).read_bytes())
manifest = {'elf_entry': hex(entry), 'cpu_reset_pc': '0x0', 'application_entry': '0x1000',
            'itcm_bytes':ITCM_BYTES,'dtcm_bytes':32768,'stack_bottom':'0x17000','stack_top':'0x18000',
            'data_initialization':'ITCM LMA -> DTCM VMA copy on every reset',
            'segments':segments,'symbols':symbols,'instruction_count':len(instructions),
            'load_funct3_audit':load_kinds,'store_funct3_audit':store_kinds,
            'status':'BUILD_ONLY_REQUIRES_B_TIMER_HARDWARE', 'mode':args.mode,'iterations':args.iterations,'build_id':identity,'upstream_commit':lock['commit'], 'tools':versions,'build_command':command,
            'sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(out.iterdir())
                      if p.is_file() and p.name != 'build_manifest.json'}}
(out / 'build_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('PASS build: RV32I ELF, map, disassembly, separate TCM images; entry=' + hex(entry))
