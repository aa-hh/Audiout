import math,sys
def r(x): return math.floor(x+0.5)  # Swift .rounded() for x>=0
def nxt(c,up,fine,fix=False):
    d=64.0 if fine else 16.0; s=100.0/d
    if fix:
        stops=[int(r(k*s)) for k in range(int(d)+1)]
        cand=[x for x in stops if (x>c if up else x<c)]
        return (min(cand) if up else max(cand)) if cand else (100 if up else 0)
    else: i=r(c/s)+(1 if up else -1)
    m=min(max(i,0),d); return int(r(m*s))
def run(fix):
    bad=[]
    for c,up,exp in [(4,True,6),(5,True,6),(7,False,6),(8,False,6)]:
        g=nxt(c,up,False,fix)
        if g!=exp: bad.append((c,up,exp,g))
    # on-grid still works
    assert [nxt(c,True,False,fix) for c in (0,6,13)]==[6,13,19]
    assert [nxt(c,False,False,fix) for c in (19,13,6)]==[13,6,0]
    return bad
b=run(False);print("current",b)
f=run(True);print("fixed",f)
sys.exit(1 if b else 0)
