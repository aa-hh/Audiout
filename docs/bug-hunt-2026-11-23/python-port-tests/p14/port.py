# Faithful port of NativeBackend setMuted (AP2 engine arm), setSpeakerVolume,
# restoreEffectiveVolume, effectiveVolume, DACPServer.level(fromDb:).
import sys
FIX = "--fix" in sys.argv
def clamp(v): return max(0, min(100, v))
def swift_round(x):  # .rounded() = schoolbook, half away from zero
    import math; return int(math.floor(x+0.5)) if x>=0 else -int(math.floor(-x+0.5))
def level_from_db(db):
    if db <= -30: return 0.0
    if db >= 0: return 1.0
    return (db+30)/30
def db_from_engine(v):  # airplay_volume_from_pct: 0..1 -> -30..0 dB
    return -30 + 30*v
class B:
    def __init__(s, vol):
        s.known={'d':vol}; s.muted=set(); s.stash={}; s.gain=1.0; s.wire=[]
    def eff(s, id): return clamp(swift_round(s.known[id]*s.gain))
    def push(s, v): s.wire.append(v)
    def set_muted(s, id, m):
        if (id in s.muted) == m: return
        if m:
            s.muted.add(id)
            if id not in s.stash: s.stash[id]=s.known[id]
            s.known[id]=0
            s.push(min(max(0/100,0.0),1.0))
        else:
            s.muted.discard(id)
            intended = s.stash.pop(id, s.known[id])
            s.known[id]=intended
            s.push(intended*s.gain/100)
    def set_speaker_volume(s, id, level):
        g=s.gain
        if not g>0: return
        wire=clamp(swift_round(level*100)); stored=clamp(swift_round(wire/g))
        if id in s.muted:
            if FIX and wire == s.eff(id): return   # fix: drop the echo of our own mute write
            s.stash[id]=stored; return
        if wire == s.eff(id): return
        s.known[id]=stored; s.push(stored*g/100)
b=B(70)
b.set_muted('d',True)
# receiver reflects our last wire write over DACP
b.set_speaker_volume('d', level_from_db(db_from_engine(b.wire[-1])))
b.set_muted('d',False)
print("after unmute volume =", b.known['d'], "wire =", b.wire[-1])
assert b.known['d']==70, f"FAIL: unmute restored {b.known['d']} instead of 70"
# genuine knob turn while muted still stashes
c=B(70); c.set_muted('d',True); c.set_speaker_volume('d',0.40); c.set_muted('d',False)
assert c.known['d']==40, c.known['d']
print("PASS")
