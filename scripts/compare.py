#!/usr/bin/env python3
"""Section 4.2/4.4: side-by-side table of all collected metrics.

    python3 scripts/compare.py lab_O0 lab_O3 [lab_O3sse]

Reads results/<name>/{time_v.txt, perf_stat.csv, out.folded, energy.txt}.
Missing files/counters are shown as '-'.
"""
import os, re, sys

def read(p):
    return open(p).read() if os.path.exists(p) else ""

def time_v(d):
    t = read(f"{d}/time_v.txt"); r = {}
    pats = {"wall, s": r"Elapsed.*?: (?:(\d+):)?(\d+):([\d.]+)",
            "user, s": r"User time.*?: ([\d.]+)",
            "sys, s": r"System time.*?: ([\d.]+)",
            "%CPU": r"Percent of CPU.*?: (\d+)%",
            "max RSS, MiB": r"Maximum resident.*?: (\d+)",
            "minor faults": r"Minor.*?: (\d+)",
            "major faults": r"Major.*?: (\d+)",
            "vol. ctx sw": r"Voluntary context.*?: (\d+)",
            "invol. ctx sw": r"Involuntary context.*?: (\d+)"}
    for k, p in pats.items():
        m = re.search(p, t)
        if not m: continue
        if k == "wall, s":
            h, mi, s = m.groups(); r[k] = (int(h or 0) * 60 + int(mi)) * 60 + float(s) \
                if h else int(mi) * 60 + float(s)
        elif k == "max RSS, MiB": r[k] = int(m.group(1)) / 1024
        else: r[k] = float(m.group(1))
    return r

def perf_stat(d):
    ev = {}
    for line in read(f"{d}/perf_stat.csv").splitlines():
        f = line.split(",")
        if len(f) < 3 or line.startswith("#"): continue
        try: v = float(f[0])
        except ValueError: continue
        name = re.sub(r"^cpu_(core|atom)/|/$", "", f[2]).replace(":u", "")
        if f[2].startswith("cpu_atom"): continue      # hybrid Intel: keep P-core numbers
        ev[name] = ev.get(name, 0) + v
    r = {}
    g = ev.get
    if g("task-clock"): r["task-clock, ms"] = g("task-clock")
    if g("cycles"): r["cycles, 1e9"] = g("cycles") / 1e9
    if g("instructions"): r["instructions, 1e9"] = g("instructions") / 1e9
    if g("cycles") and g("instructions"): r["IPC"] = g("instructions") / g("cycles")
    if g("cycles") and g("task-clock"): r["avg GHz"] = g("cycles") / g("task-clock") / 1e6
    if g("branches"): r["branches, 1e9"] = g("branches") / 1e9
    if g("branches") and g("branch-misses") is not None:
        r["branch-miss %"] = 100 * g("branch-misses") / g("branches")
    if g("L1-dcache-loads"): r["L1d loads, 1e9"] = g("L1-dcache-loads") / 1e9
    if g("L1-dcache-loads") and g("L1-dcache-load-misses") is not None:
        r["L1d miss %"] = 100 * g("L1-dcache-load-misses") / g("L1-dcache-loads")
    if g("LLC-loads") and g("LLC-load-misses") is not None:
        r["LLC miss %"] = 100 * g("LLC-load-misses") / g("LLC-loads")
    if g("page-faults") is not None: r["page-faults"] = g("page-faults")
    return r

def kernels(d):
    tot, inc = 0, {}
    for line in read(f"{d}/out.folded").splitlines():
        stack, n = line.rsplit(" ", 1); n = int(n); tot += n
        frames = set(stack.split(";"))
        for k in ("matmul", "saxpy", "branchy_sum", "fib", "fill_random_f",
                  "fill_random_i", "main"):
            if k in frames: inc[k] = inc.get(k, 0) + n
    return {f"flame % {k}": 100 * v / tot for k, v in inc.items()} if tot else {}

def energy(d):
    t = read(f"{d}/energy.txt"); r = {}
    for k, p in {"E_sys/run, J": r"SYSTEM energy/run\s+E_sys = ([\d.]+)",
                 "E_prog A, J": r"A \(marginal.*?= ([\d.]+)",
                 "E_prog B, J": r"B \(CPU-time.*?= ([\d.]+)",
                 "E_cores C, J": r"C \(cores.*?= ([\d.]+)",
                 "EDP, J*s": r"EDP = E_sys \* t = ([\d.]+)"}.items():
        m = re.search(p, t)
        if m: r[k] = float(m.group(1))
    m = re.search(r"^package\S*\s+([\d.]+)\s+([\d.]+)", t, re.M)
    if m: r["P_idle pkg, W"], r["P_run pkg, W"] = float(m.group(1)), float(m.group(2))
    return r

names = sys.argv[1:] or ["lab_O0", "lab_O3"]
data = {n: {**time_v(f"results/{n}"), **perf_stat(f"results/{n}"),
            **kernels(f"results/{n}"), **energy(f"results/{n}")} for n in names}
keys = []
for n in names:
    for k in data[n]:
        if k not in keys: keys.append(k)

w = max(len(k) for k in keys) + 2
hdr = f"{'metric':<{w}}" + "".join(f"{n:>13}" for n in names)
if len(names) >= 2: hdr += f"{names[0]+'/'+names[1]:>16}"
print(hdr); print("-" * len(hdr))
for k in keys:
    row = f"{k:<{w}}"
    for n in names:
        v = data[n].get(k)
        row += f"{'-':>13}" if v is None else f"{v:>13.3f}" if abs(v) < 1e4 else f"{v:>13.0f}"
    a, b = data[names[0]].get(k), (data[names[1]].get(k) if len(names) > 1 else None)
    if a is not None and b and not k.startswith('flame'):
        row += f"{a / b:>15.2f}x"
    print(row)
