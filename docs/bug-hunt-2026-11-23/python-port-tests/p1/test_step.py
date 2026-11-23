# Port of NativeBackend.applyDacpVolumeStep -> setSpeakerVolume (lines ~5700-5745, 5975)
import math, sys
def rnd(x): return math.floor(x+0.5) if x>=0 else -math.floor(-x+0.5)  # Swift .rounded() (away from zero)
def clamp(v): return max(0,min(100,v))
STEP=2
class Backend:
    def __init__(s, main, group, vol, fixed=False):
        s.mainOutGain, s.groupGain, s.vol, s.fixed, s.pushes = main, group, vol, fixed, []
    def gain(s): return s.mainOutGain/100*s.groupGain/100
    def effective(s): return clamp(rnd(s.vol*s.gain()))
    def setSpeakerVolume(s, level, storedLevel=None):
        g=s.gain()
        if not g>0: return
        wire=clamp(rnd(level*100))
        stored = storedLevel if storedLevel is not None else clamp(rnd(wire/g))
        if storedLevel is None:
            if wire==s.effective(): return
        else:
            if stored==s.vol: return
        s.vol=stored; s.pushes.append(stored)
    def step(s, d):
        target=clamp(s.vol + (1 if d>0 else -1)*STEP)
        lvl=target*s.gain()/100
        if s.fixed: s.setSpeakerVolume(lvl, storedLevel=target)
        else: s.setSpeakerVolume(lvl)
fixed = len(sys.argv)>1 and sys.argv[1]=="fixed"
ok=True
for main,group in [(50,50),(10,100),(100,100)]:
    b=Backend(main,group,50,fixed)
    for _ in range(5): b.step(+1)
    good = b.vol==60
    ok &= good
    print(f"{'PASS' if good else 'FAIL'} gain={b.gain():.2f} after 5x volumeup: volume={b.vol} (expected 60), pushes={b.pushes}")
# echo path still guarded (absolute report equal to effective wire level is dropped)
b=Backend(50,50,50,fixed); b.setSpeakerVolume(b.effective()/100); 
e = b.pushes==[]; ok&=e; print(("PASS" if e else "FAIL")+" echo of own write still dropped")
sys.exit(0 if ok else 1)
