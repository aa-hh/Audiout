import sys
class D:
    def __init__(s, fix=False):
        s.base=s.prev=None; s.pst=None; s.stable=0.0; s.dev=0.0; s.fix=fix
    def observe(s, st, h, rate):
        if st == s.pst:
            s.base=s.prev=None; s.dev=0; return 'frozen'
        s.pst=st
        if s.base is None:
            s.base=s.prev=(st,h,0.0)
            if not s.fix: s.stable=0
            s.dev=0; return 'ignored'
        b=s.base
        if st<b[0] or h<=b[1]:
            s.base=s.prev=(st,h,0.0); s.stable=0; s.dev=0; return 'rebaselined'
        el=(h-b[1])/1e9; dev=((st-b[0])/rate-el)*1000
        s.dev=dev; last=s.prev or b; s.prev=(st,h,dev)
        step=dev-last[2]
        if abs(step)>=1000: s.base=s.prev=(st,h,0.0); s.stable=0; s.dev=0; return 'rebaselined'
        if abs(step)>2: s.stable=0; return 'jumped'
        s.stable+=(h-last[1])/1e9; return 'advanced'
def run(fix):
    d=D(fix); R=48000.0; t=0
    for i in range(12): d.observe(i*R, i*10**9, R)
    assert d.stable>=10, d.stable
    before=d.stable
    assert d.observe(11*R, 12*10**9, R)=='frozen'
    d.observe(13*R, 13*10**9, R); d.observe(14*R, 14*10**9, R)
    assert d.stable>=before, f"stable {before} -> {d.stable}"
for fix in (False,True):
    try: run(fix); print("fix" if fix else "cur","PASS")
    except AssertionError as e: print("fix" if fix else "cur","FAIL",e)
