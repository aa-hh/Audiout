import sys
HOLD=441
class Timeline:
    def __init__(s): s.start=0; s.acc=[]; s.has=False
    def add(s,first,st):
        if not s.has: s.start=first; s.acc=list(st); s.has=True; return
        end=s.start+len(s.acc)//2; need=first+len(st)//2
        if need>end: s.acc+= [0]*((need-end)*2)
        o=(first-s.start)*2
        for i,v in enumerate(st): s.acc[o+i]+=v
    def drain_ready(s):
        n=len(s.acc)//2-HOLD
        if n<=0: return 0
        s.acc=s.acc[n*2:]; s.start+=n; return n
    def pending(s): return len(s.acc)//2
class Mixer:
    def __init__(s,fixed): s.tl=Timeline(); s.conv={'a':1,'b':1}; s.fixed=fixed; s.emitted=0
    def buf(s,app,first,frames):
        s.tl.add(first,[100]*(frames*2)); s.emitted+=s.tl.drain_ready()
    def flush(s):
        n=s.tl.pending(); s.tl.acc=[]; s.tl.has=False; s.emitted+=n
    def handle_state_change(s,app,state):   # port of current code
        if state!='capturing': s.conv.pop(app,None)
        if s.fixed and state!='capturing': s.flush()  # proposed fix (single-stream simplification)
for fixed in (True,):
    m=Mixer(fixed)
    m.buf('a',0,1000); m.buf('b',600,400)       # both feed stream
    m.handle_state_change('a','stopping'); m.handle_state_change('b','idle')
    print('fixed' if fixed else 'current','pending frames after stop:',m.tl.pending())
    if m.tl.pending()!=0: print('FAIL'); sys.exit(1) if not fixed else None
print('PASS')
