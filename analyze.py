import sys, statistics as st
from collections import defaultdict
rows=[]
for l in open(sys.argv[1]):
    l=l.rstrip('\n')
    if not l or l.startswith('#') or l.startswith('arm\t'): continue
    f=l.split('\t')
    rows.append(dict(arm=f[0], idx=int(f[1]), PP=float(f[5]), TG=float(f[6]),
                     draft=float(f[7]), sclk=float(f[8]), busy=float(f[9]),
                     W=float(f[10]), T=float(f[11])))
DROP=int(sys.argv[2]) if len(sys.argv)>2 else 1
def show(title, keep):
    print(f"\n{title}")
    print(f"{'arm':<26}{'n':>3}{'PP mean':>9}{'sd':>7}{'PP range':>16}{'TG mean':>9}{'sd':>6}"
          f"{'sclk':>7}{'W':>7}{'degC':>6}{'draft%':>8}")
    g=defaultdict(list)
    for r in rows:
        if keep(r): g[r['arm']].append(r)
    for arm in sorted(g):
        v=g[arm]; pp=[x['PP'] for x in v]; tg=[x['TG'] for x in v]
        sd=st.stdev(pp) if len(pp)>1 else 0.0
        tsd=st.stdev(tg) if len(tg)>1 else 0.0
        print(f"{arm:<26}{len(v):>3}{st.mean(pp):>9.1f}{sd:>7.1f}"
              f"{f'{min(pp):.0f}-{max(pp):.0f}':>16}{st.mean(tg):>9.2f}{tsd:>6.2f}"
              f"{st.mean([x['sclk'] for x in v]):>7.0f}{st.mean([x['W'] for x in v]):>7.1f}"
              f"{st.mean([x['T'] for x in v]):>6.1f}{st.mean([x['draft'] for x in v]):>8.1f}")
show(f"ALL REPS (n={max(r['idx'] for r in rows)} rounds)", lambda r: True)
show(f"STEADY STATE (rounds 1-{DROP} dropped, per p14 rep-order note)", lambda r: r['idx']>DROP)
print("\nPer-round PP by arm (checks for drift/thermal decay):")
arms=sorted({r['arm'] for r in rows})
print(f"{'round':<7}"+"".join(f"{a:>26}" for a in arms))
for i in sorted({r['idx'] for r in rows}):
    line=f"{i:<7}"
    for a in arms:
        v=[r['PP'] for r in rows if r['idx']==i and r['arm']==a]
        line+=f"{(f'{v[0]:.1f}' if v else '-'):>26}"
    print(line)
