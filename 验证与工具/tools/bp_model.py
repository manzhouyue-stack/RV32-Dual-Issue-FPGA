"""Trace-driven branch predictor model for rv32_core_p.

Input: retire_trace.txt ("pc instr" per retired instruction, timed CoreMark
window). The next record's PC is the real next PC. Models the RTL predictor
(direct-mapped BTB with per-entry 2-bit counter and type, RAS) and variants:
larger BTB, a separate direction table (bimodal / gshare), deeper RAS.
"""
import sys
from collections import Counter

T_BRANCH, T_JUMP, T_CALL, T_RET = range(4)


def load(path):
    recs = []
    with open(path) as f:
        for line in f:
            pc, ins = line.split()
            recs.append((int(pc, 16), int(ins, 16)))
    return recs


def classify(ins):
    op = ins & 0x7f
    rd = (ins >> 7) & 31
    rs1 = (ins >> 15) & 31
    link = lambda r: r in (1, 5)
    if op == 0x63:
        return T_BRANCH
    if op == 0x6f:
        return T_CALL if link(rd) else T_JUMP
    if op == 0x67:
        if link(rd):
            return T_CALL
        return T_RET if link(rs1) else T_JUMP
    return None


class Pred:
    def __init__(self, btb_bits=6, ras=4, dir_bits=0, hist=0, ind_hist=0):
        self.btb_bits, self.ras_n, self.dir_bits, self.hist = btb_bits, ras, dir_bits, hist
        self.ind_hist = ind_hist
        self.btb = {}          # idx -> [tag, tgt, type, ctr]
        self.dir = {}          # separate direction counters
        self.ind = {}          # indirect target cache (pc ^ history)
        self.ras = [0] * ras
        self.sp = 0
        self.ghr = 0
        self.path = 0

    def run(self, recs):
        stats = Counter()
        for i in range(len(recs) - 1):
            pc, ins = recs[i]
            nxt = recs[i + 1][0]
            kind = classify(ins)
            taken = nxt != pc + 4
            idx = (pc >> 2) & ((1 << self.btb_bits) - 1)
            tag = pc >> (2 + self.btb_bits)
            e = self.btb.get(idx)
            hit = e is not None and e[0] == tag
            # ---- predict
            if hit:
                etype = e[2]
                if etype == T_BRANCH:
                    if self.dir_bits:
                        di = ((pc >> 2) ^ (self.ghr & ((1 << self.hist) - 1))) & ((1 << self.dir_bits) - 1)
                        pt = self.dir.get(di, 1) >= 2
                    else:
                        pt = e[3] >= 2
                    ptgt = e[1]
                elif etype == T_RET:
                    pt, ptgt = True, self.ras[self.sp]
                else:
                    pt, ptgt = True, e[1]
                    if etype in (T_JUMP, T_CALL) and self.ind_hist and (ins & 0x7f) == 0x67:
                        k = (pc >> 2) ^ (self.path & ((1 << self.ind_hist) - 1))
                        ptgt = self.ind.get(k, ptgt)
            else:
                pt, ptgt = False, None
            ok = (pt == taken) and (not taken or ptgt == nxt)
            if kind is not None:
                stats[('ctrl', kind)] += 1
                if not ok:
                    stats[('miss', kind)] += 1
            elif not ok:
                stats[('miss', 'alias')] += 1
            # ---- update (architectural order, like EX update)
            if kind is None:
                if hit:
                    del self.btb[idx]
                continue
            if kind == T_CALL:
                self.sp = (self.sp + 1) % self.ras_n
                self.ras[self.sp] = pc + 4
            elif kind == T_RET:
                self.sp = (self.sp - 1) % self.ras_n
            if kind == T_BRANCH and self.dir_bits:
                di = ((pc >> 2) ^ (self.ghr & ((1 << self.hist) - 1))) & ((1 << self.dir_bits) - 1)
                c = self.dir.get(di, 1)
                self.dir[di] = min(3, c + 1) if taken else max(0, c - 1)
                self.ghr = (self.ghr << 1) | int(taken)
            if (ins & 0x7f) == 0x67 and self.ind_hist:
                k = (pc >> 2) ^ (self.path & ((1 << self.ind_hist) - 1))
                self.ind[k] = nxt
            if taken:
                self.path = (self.path << 2) ^ (nxt >> 2)
            if taken:
                ctr = 2 if not hit else min(3, e[3] + 1)
                self.btb[idx] = [tag, nxt, kind, ctr]
            elif hit:
                e[3] = max(0, e[3] - 1)
        return stats


def report(name, st, cycles_pen=3):
    misses = sum(v for k, v in st.items() if k[0] == 'miss')
    parts = ' '.join(f"{n}={st[('miss', k)]}/{st[('ctrl', k)]}" for k, n in
                     ((T_BRANCH, 'br'), (T_JUMP, 'jmp'), (T_CALL, 'call'), (T_RET, 'ret')))
    print(f"{name:34s} miss={misses:6d} ({parts} alias={st[('miss', 'alias')]}) "
          f"lost~{misses * cycles_pen}")


if __name__ == '__main__':
    recs = load(sys.argv[1])
    print(f"records={len(recs)}")
    cfgs = [
        ("RTL now: BTB64 ctr-in-BTB RAS4", dict()),
        ("BTB128", dict(btb_bits=7)),
        ("BTB256", dict(btb_bits=8)),
        ("BTB64 RAS8", dict(ras=8)),
        ("BTB64 + bimodal 512", dict(dir_bits=9)),
        ("BTB64 + gshare 512/h6", dict(dir_bits=9, hist=6)),
        ("BTB64 + gshare 1k/h8", dict(dir_bits=10, hist=8)),
        ("BTB64 + gshare 2k/h10", dict(dir_bits=11, hist=10)),
        ("BTB128 + gshare 1k/h8", dict(btb_bits=7, dir_bits=10, hist=8)),
        ("BTB64 + gshare 1k/h8 + ind 6", dict(dir_bits=10, hist=8, ind_hist=6)),
        ("BTB64 + gshare 1k/h8 + ind 10", dict(dir_bits=10, hist=8, ind_hist=10)),
    ]
    for name, kw in cfgs:
        report(name, Pred(**kw).run(recs))
