"""Compute exact-tick derived figures, not an independent certification."""
import argparse,re,json
from decimal import Decimal, getcontext
from pathlib import Path
getcontext().prec=40
p=argparse.ArgumentParser()
p.add_argument('log',type=Path)
a=p.parse_args()
s=a.log.read_text(errors='replace')
rows=[]
for ticks,hz,cpu,iters in re.findall(r'CM_TICKS_HEX=([0-9a-fA-F]{16}) TIMER_HZ=(\d+) CPU_HZ=(\d+) ITERATIONS=(\d+)',s):
    t=int(ticks,16);h=int(hz);c=int(cpu);n=int(iters)
    if min(t,h,c,n)<=0: raise SystemExit('Invalid zero timing/iteration field')
    seconds=Decimal(t)/h
    rows.append(dict(ticks=t,timer_hz=h,cpu_hz=c,iterations=n,seconds=str(seconds),
        derived_coremark=str(Decimal(n)*h/t),derived_coremark_per_mhz=str(Decimal(n)*h*1000000/(t*c)),
        duration_at_least_10_seconds=t>=10*h))
if not rows: raise SystemExit('No complete 64-bit timing record')
print(json.dumps({'kind':'derived_from_raw_ticks_not_official_certification','records':rows},indent=2))
