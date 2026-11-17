import sys, re, datetime as dt
# usage: agg_iostat.py <iostat.txt> <events.txt> <meta_start_iso>
io, ev, start = sys.argv[1], sys.argv[2], sys.argv[3]
t0 = dt.datetime.strptime(start, "%Y-%m-%dT%H:%M:%SZ")
rows = []  # (w/s, wkB/s, %util)
for line in open(io):
    p = line.split()
    if len(p) > 10 and p[0] == 'vda':
        rows.append((float(p[7]), float(p[8]), float(p[-1])))
def idx(ts):
    t = dt.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
    return int((t - t0).total_seconds())
wins = []; cur = None
for line in open(ev):
    ts, rest = line.split(' ', 1)
    if rest.startswith('BEGIN'):
        cur = [rest.strip()[6:], idx(ts), None]
    elif rest.startswith('END') and cur:
        cur[2] = idx(ts); wins.append(cur); cur = None
print(f"rows={len(rows)} run_avg_wkBps={sum(r[1] for r in rows)/len(rows):.0f} run_peak_wkBps={max(r[1] for r in rows):.0f} run_total_wMiB={sum(r[1] for r in rows)/1024:.0f}")
for name, a, b in wins:
    seg = rows[max(0,a-1):b+2]
    if not seg: continue
    tot = sum(r[1] for r in seg); pk = max(r[1] for r in seg); pku = max(r[2] for r in seg)
    print(f"{name:28s} secs={len(seg):3d} wMiB_total={tot/1024:7.1f} peak_wkBps={pk:9.0f} peak_util%={pku:5.1f}")
