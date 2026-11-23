# Faithful port: CastRoomDelay.swift, NativeBackend+Tone.swift pushCastFeedDelaysLocked,
# NativeBackend.swift roomDelayLocked, CastOutputManager setCastRoomDelayMs/applyFeedDelay/setDelayMs
import statistics
DEFAULT=5500; MAXT=9500; N=10; BAND=100; CORR=150
class CastRoomDelay:
    def __init__(s): s.rx={}; s.mem={}; s.termMs=None
    def setReceivers(s,ids):
        w=set(ids)
        if w==set(s.rx): return False
        s.rx={k:v for k,v in s.rx.items() if k in w}
        for i in w:
            if i not in s.rx: s.rx[i]=dict(term=s.mem.get(i,DEFAULT),settled=None,win=[],refused=False)
        return s.commit()
    def ingest(s,lead,i):
        r=s.rx.get(i)
        if r is None: return None
        if r['settled'] is not None:
            if abs(lead-r['settled'])<=CORR: return None
            r['settled']=None
        r['win'].append(lead)
        while max(r['win'])-min(r['win'])>2*BAND: r['win'].pop(0)
        if len(r['win'])<N: return None
        srt=sorted(r['win']); m=len(srt)//2
        st=(srt[m-1]+srt[m])//2 if len(srt)%2==0 else srt[m]
        r['win']=[]; r['settled']=st; r['refused']=st>MAXT
        if r['refused']: s.mem.pop(i,None)
        else:
            s.mem[i]=st
            if st>r['term']+CORR: r['term']=st
        return st, s.commit()
    def settledLeadMs(s,i):
        r=s.rx.get(i)
        return None if r is None or r['refused'] else r['settled']
    def refusedIDs(s): return {k for k,v in s.rx.items() if v['refused']}
    def commit(s):
        vals=[v['term'] for v in s.rx.values() if not v['refused']]
        u=max(vals) if vals else None
        if u==s.termMs: return False
        s.termMs=u; return True

class Session:
    def __init__(s): s.roomDelayMs=0; s.userOffsetMs=0; s.applied=0; s.line=False
    def apply(s):
        ms=max(0,s.roomDelayMs+s.userOffsetMs)
        if s.line: s.applied=ms
        elif ms>0: s.line=True; s.applied=ms
class CastOutputManager:
    def __init__(s): s.sessions={}
    def setCastRoomDelayMs(s,ms,i):
        se=s.sessions.get(i)
        if se is None: return
        se.roomDelayMs=ms; se.apply()

class Backend:
    def __init__(s,fixed=False):
        s.crd=CastRoomDelay(); s.com=CastOutputManager(); s.sel=[]; s.startBuffer=2000; s.fixed=fixed
    def room(s): return max([s.startBuffer]+[t for t in [s.crd.termMs] if t is not None])
    def push(s):
        room=s.room(); ref=s.crd.refusedIDs()
        for i in s.sel:
            if i in ref: continue
            st=s.crd.settledLeadMs(i)
            if st is None: continue
            rem=room-st
            if s.fixed: rem=max(0,rem)
            elif not rem>0: continue
            s.com.setCastRoomDelayMs(rem,i)
    def select(s,ids):
        s.sel=list(ids)
        for i in ids: s.com.sessions.setdefault(i,Session())
        for i in list(s.com.sessions):
            if i not in ids: del s.com.sessions[i]
        if s.crd.setReceivers(s.sel): s.push()   # roomDelayChangedLocked -> push
    def sample(s,i,lead):
        r=s.crd.ingest(lead,i)
        if r is None: return
        s.push()  # termMoved or not, push runs (directly or via roomDelayChangedLocked)
