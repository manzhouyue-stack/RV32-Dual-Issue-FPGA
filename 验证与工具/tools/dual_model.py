"""Trace-driven in-order superscalar timing model (CoreMark timed window).

Feeds the retire trace through: a fetch stage delivering up to FW sequential
instructions per cycle (a predicted-taken control transfer ends the group),
an issue stage with up to W in-order slots, operand latency (ALU 1 cycle,
load/mul 2), one memory port, and mispredict refetch penalty. Predictions come
from bp_model.Pred (the RTL BTB/RAS predictor). Calibrate with W=1 against RTL.
"""
import sys
from bp_model import load, classify, Pred, T_BRANCH

OP_LOAD, OP_STORE, OP_BRANCH, OP_JAL, OP_JALR = 0x03, 0x23, 0x63, 0x6f, 0x67


def decode(ins):
    op = ins & 0x7f
    rd = (ins >> 7) & 31
    rs1 = (ins >> 15) & 31
    rs2 = (ins >> 20) & 31
    f7 = ins >> 25
    f3 = (ins >> 12) & 7
    srcs = []
    if op in (OP_LOAD, 0x13, OP_JALR):
        srcs = [rs1]
    elif op in (OP_STORE, OP_BRANCH, 0x33):
        srcs = [rs1, rs2]
    if op == 0x33 and f7 == 0x30 and False:
        pass
    if op == 0x13 and f3 in (1, 5) and (ins >> 20) in (0x600, 0x601, 0x602, 0x604, 0x605, 0x287, 0x698):
        srcs = [rs1]
    srcs = [r for r in srcs if r]
    writes = rd if op in (0x33, 0x13, OP_LOAD, 0x37, 0x17, OP_JAL, OP_JALR) and rd else 0
    kind = 'alu'
    if op == OP_LOAD:
        kind = 'load'
    elif op == OP_STORE:
        kind = 'store'
    elif op == 0x33 and f7 == 1:
        kind = 'div' if f3 >= 4 else 'mul'
    elif op in (OP_BRANCH, OP_JAL, OP_JALR):
        kind = 'ctrl'
    return kind, srcs, writes


def predictions(recs, **kw):
    """Per-instruction (predicted_taken_correctly, mispredicted) using the RTL predictor."""
    p = Pred(**kw)
    out = []
    # Re-implement Pred.run's predict/update but record per-instruction outcome.
    for i in range(len(recs) - 1):
        pc, ins = recs[i]
        nxt = recs[i + 1][0]
        kind = classify(ins)
        taken = nxt != pc + 4
        idx = (pc >> 2) & ((1 << p.btb_bits) - 1)
        tag = pc >> (2 + p.btb_bits)
        e = p.btb.get(idx)
        hit = e is not None and e[0] == tag
        if hit:
            if e[2] == T_BRANCH:
                if p.dir_bits:
                    di = ((pc >> 2) ^ (p.ghr & ((1 << p.hist) - 1))) & ((1 << p.dir_bits) - 1)
                    pt = p.dir.get(di, 1) >= 2
                else:
                    pt = e[3] >= 2
                ptgt = e[1]
            elif e[2] == 3:
                pt, ptgt = True, p.ras[p.sp]
            else:
                pt, ptgt = True, e[1]
        else:
            pt, ptgt = False, None
        ok = (pt == taken) and (not taken or ptgt == nxt)
        out.append((taken, not ok))
        # update (same as Pred.run)
        if kind is None:
            if hit:
                del p.btb[idx]
            continue
        if kind == 2:
            p.sp = (p.sp + 1) % p.ras_n
            p.ras[p.sp] = pc + 4
        elif kind == 3:
            p.sp = (p.sp - 1) % p.ras_n
        if kind == T_BRANCH and p.dir_bits:
            di = ((pc >> 2) ^ (p.ghr & ((1 << p.hist) - 1))) & ((1 << p.dir_bits) - 1)
            c = p.dir.get(di, 1)
            p.dir[di] = min(3, c + 1) if taken else max(0, c - 1)
            p.ghr = (p.ghr << 1) | int(taken)
        if taken:
            ctr = 2 if not hit else min(3, e[3] + 1)
            p.btb[idx] = [tag, nxt, kind, ctr]
        elif hit:
            e[3] = max(0, e[3] - 1)
    out.append((False, False))
    return out


def simulate(recs, W=2, FW=None, mem_ports=1, mul_ports=1, lat_load=2, lat_mul=2,
             mispredict_gap=3, cascade=False, sfb=True, pred=None, div_lat=34, late_alu=False, hybrid=False, slot0_only=()):
    """late_alu: AG stage (address/mem request) precedes the ALU stage, so a load
    feeds an ALU consumer with no bubble, but ALU/load results feeding a memory
    address need one extra cycle, and branches resolve one stage later."""
    FW = FW or W
    info = [decode(ins) for _, ins in recs]
    pred = pred or predictions(recs)
    n = len(recs)
    ready = [0] * 32       # earliest issue cycle for ALU/branch/store-data consumers
    ready_ag = [0] * 32    # earliest issue cycle for address (load/store base) consumers
    # fetch availability: earliest cycle each instruction can be in the issue window
    avail = [0] * n
    cyc, i = 0, 0
    issue_cycle = [0] * n
    restart = 0          # earliest issue cycle imposed by the last mispredict
    fetch_cycle = 0
    group = 0
    # Fetch timeline (decoupled; refetch after mispredict handled at issue)
    for k in range(n):
        if group == FW:
            fetch_cycle += 1
            group = 0
        avail[k] = fetch_cycle
        group += 1
        taken, miss = pred[k]
        pc, ins = recs[k]
        # SFB: short forward branch (+8/+12) never redirects fetch
        if taken and not miss:
            fetch_cycle += 1
            group = 0
    k = 0
    cycle = 0
    shift = 0            # fetch timeline delay accumulated by mispredict refetches
    lost = {}
    while k < n:
        issued = 0
        mem_used = mul_used = 0
        mem_kinds = set()
        pair_writes = {}
        why = None
        while issued < W and k < n:
            kind, srcs, wr = info[k]
            if cycle < restart:
                why = 'mispredict'
                break
            if avail[k] + shift > cycle:
                why = 'fetch'
                break
            # same-cycle dependence on the older slot: only ALU->ALU cascade allowed
            inpair = [r for r in srcs if r in pair_writes]
            if inpair and not (cascade and kind in ('alu', 'ctrl') and
                               all(pair_writes[r] == 'alu' for r in inpair)):
                why = 'pair_dep'
                break
            older = [r for r in srcs if r not in pair_writes]
            if kind in ('load', 'store'):
                base = [r for r in srcs[:1] if r in older]
                rest = [r for r in srcs[1:] if r in older]
                if any(ready_ag[r] > cycle for r in base):
                    why = 'addr_dep'
                    break
                if any(ready[r] > cycle for r in rest):
                    why = 'data_dep'
                    break
            elif any(ready[r] > cycle for r in older):
                why = 'load_use' if any(ready[r] - cycle >= 1 and ready[r] > cycle for r in older) else 'data_dep'
                break
            if issued > 0 and kind in slot0_only:
                why = 'slot0_only'
                break
            if kind in ('load', 'store'):
                # mem_ports: 1 = one access/cycle; 'ldst' = one load + one store;
                # 2 = any two accesses
                if mem_ports == 'ldst':
                    if kind in mem_kinds:
                        why = 'mem_port'
                        break
                    mem_kinds.add(kind)
                elif mem_used >= mem_ports:
                    why = 'mem_port'
                    break
                mem_used += 1
            if kind in ('mul', 'div'):
                if mul_used >= mul_ports:
                    why = 'mul_port'
                    break
                mul_used += 1
            lat = lat_load if kind == 'load' else lat_mul if kind == 'mul' else div_lat if kind == 'div' else 1
            if late_alu and kind == 'load':
                lat = 1
            # hybrid: an ALU op whose operands are already available at the early
            # (AG) stage executes there, so its result can also feed an address
            # next cycle; otherwise it executes in the late ALU.
            early = hybrid and kind in ('alu', 'ctrl') and all(ready_ag[r] <= cycle for r in older)                 and not inpair
            if wr:
                ready[wr] = cycle + lat
                ready_ag[wr] = cycle + (lat if (not late_alu or early) else lat + 1)
                pair_writes[wr] = kind if not (hybrid and not early and kind == 'alu') else 'late'
            issue_cycle[k] = cycle
            taken, miss = pred[k]
            issued += 1
            k += 1
            if miss:
                restart = cycle + mispredict_gap + (1 if late_alu and not early else 0)
                # everything younger is refetched: re-time the fetch stream
                shift = restart - avail[k] if k < n else 0
                break
            if kind == 'div':
                restart = max(restart, cycle + div_lat)
        if issued < W and k < n:
            lost[why or 'other'] = lost.get(why or 'other', 0) + (W - issued)
        cycle += 1
    simulate.lost = lost
    return cycle


if __name__ == '__main__':
    recs = load(sys.argv[1])
    pred = predictions(recs)
    miss = sum(m for _, m in pred)
    print(f"instructions={len(recs)} mispredicts={miss}")
    base = simulate(recs, W=1, pred=pred)
    print(f"W=1 (calibration vs RTL 327433): cycles={base} CM/MHz={1e6 / base:.3f}")
    print(f"W=1 late-ALU: cycles={simulate(recs, W=1, pred=pred, late_alu=True)}")
    for name, kw in [
        ("W=2 baseline (1 mem, 1 mul)", dict(W=2)),
        ("W=2 late-ALU", dict(W=2, late_alu=True)),
        ("W=2 late-ALU + cascade", dict(W=2, late_alu=True, cascade=True)),
        ("W=2 late-ALU + cascade + gap2", dict(W=2, late_alu=True, cascade=True, mispredict_gap=2)),
        ("W=2 late-ALU + cascade + gap2 + 2mem", dict(W=2, late_alu=True, cascade=True, mispredict_gap=2, mem_ports=2)),
        ("W=2 + cascade ALU pairs", dict(W=2, cascade=True)),
        ("W=2 mispredict gap 2", dict(W=2, mispredict_gap=2)),
        ("W=2 load latency 1 (load->use 0 bubble)", dict(W=2, lat_load=1)),
        ("W=2 fetch 4/cycle", dict(W=2, FW=4)),
        ("W=2 2 mem ports", dict(W=2, mem_ports=2)),
        ("W=2 cascade+gap2+fetch4", dict(W=2, cascade=True, mispredict_gap=2, FW=4)),
        ("W=3 cascade+gap2+fetch4", dict(W=3, cascade=True, mispredict_gap=2, FW=4)),
    ]:
        c = simulate(recs, pred=pred, **kw)
        print(f"{name:42s} cycles={c} IPC={len(recs) / c:.3f} CM/MHz={1e6 / c:.3f}")
