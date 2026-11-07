"""Run RV32I CPU with a protocol RAM/UART/timer test double, NOT B IP."""
import subprocess,json,hashlib,sys,re,os
from pathlib import Path
here=Path(__file__).resolve().parent
root=here.parent.parent
out=root/'output/coremark_validation';out.mkdir(parents=True,exist_ok=True)
def run(command,log,timeout=1800):
    r=subprocess.run(command,capture_output=True,text=True,timeout=timeout)
    (out/log).write_text(r.stdout+r.stderr)
    if r.returncode: raise RuntimeError(log+' failed: '+(r.stdout+r.stderr)[-1800:])
    return r.stdout
for mode in ['smoke','performance','validation']:
    run([sys.executable,str(here/'build.py'),'--mode',mode,'--iterations','1'], 'build_'+mode+'.log')
rtl=[root/'rtl/rv32_pkg.sv',*[root/'rtl'/n for n in ['rv32_alu.sv','rv32_decode.sv','rv32_hazard.sv','rv32_imm.sv','rv32_regfile.sv','rv32_core_b.sv']]]
exe=out/'coremark.vvp'
run(['iverilog','-g2012','-s','tb_coremark','-o',str(exe),*map(str,rtl),str(root/'tests/b_protocol_memory.sv'),str(root/'tests/tb_coremark.sv')],'compile.log')
fast=out/'obj_fast'
run(['verilator','--cc','--exe','-Wno-fatal','--top-module','coremark_fast','--Mdir',str(fast),*map(str,rtl),str(root/'tests/b_protocol_memory.sv'),str(root/'tests/coremark_fast.sv'),str(root/'tests/coremark_fast.cpp')],'fast_generate.log')
run(['make','-C',str(fast),'-f','Vcoremark_fast.mk','-j2'],'fast_compile.log')
cases=[]
for mode,negative,expected in [('smoke',0,1),('smoke',6,15),('smoke',7,21),('performance',0,19),('validation',0,19)]:
    name=mode+('_negative'+str(negative) if negative else '')
    backend=['vvp',str(exe)] if mode=='smoke' else [str(fast/'Vcoremark_fast')]
    s=run([*backend,'+itcm='+str(here/('build_'+mode)/'itcm_full.mem'),'+expected='+str(expected),'+negative='+str(negative)], name+'.log')
    if s.count('PASS_MODEL round=')!=2: raise RuntimeError('Two-reset check failed: '+name)
    if mode!='smoke':
        crcs={'performance':['e714','1fd7','8e3a'],'validation':['e3c1','0747','8d84']}[mode]
        for kind,crc in zip(['crclist','crcmatrix','crcstate'],crcs):
            if len(re.findall(kind+r'\s*: 0x'+crc,s))!=2: raise RuntimeError('CRC mismatch '+name+' '+kind)
        if s.count('ERROR! Must execute for at least 10 secs')!=2: raise RuntimeError('Short run incorrectly accepted')
        if 'Correct operation validated.' in s: raise RuntimeError('Short run claimed valid')
    cases.append({'name':name,'resets':2,'expected_result':expected,'passed':True,'backend':'icarus_pin_decode' if mode=='smoke' else 'verilator_uart_busy_model'})
    print('PASS '+name,flush=True)
inputs=[*rtl,root/'tests/b_protocol_memory.sv',root/'tests/tb_coremark.sv',root/'tests/coremark_fast.sv',root/'tests/coremark_fast.cpp',*[p for p in here.iterdir() if p.is_file()]]
report={'status':'PASS_CPU_PROTOCOL_MODEL_ONLY','b_actual_ip_or_board_tested':False,'formal_coremark_score':False,'cases':cases,'source_sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}}
(out/'report.json').write_text(json.dumps(report,indent=2))
