import sys
class M:
    def __init__(s,fix=False):
        s.fix=fix; s.skipped=set(); s.granted=True; s.decided={'bluetooth'}; s.fc='pending'
    def active(s):  # undecided & unskipped step
        return next((x for x in ['bluetooth'] if x not in s.decided and x not in s.skipped),None)
    def ready(s): return s.granted and s.active() is None
    def state(s): return s.fc if s.ready() else 'pending'
    def reopen(s,x):
        if x in s.skipped:
            s.skipped.discard(x); s.decided.discard(x)
            if s.fix: s.fc='pending'
    def skip(s,x): s.skipped.add(x)
    def run(s): s.fc='passed'
def test(fix):
    m=M(fix); m.decided=set(); m.skipped={'bluetooth'}
    m.run(); assert m.state()=='passed'
    m.reopen('bluetooth'); assert m.state()=='pending'
    m.skip('bluetooth')
    assert m.state()=='pending', "stale %s without new audit"%m.state()
    m.run(); m.granted=False; assert m.state()=='pending'
    m.granted=True
test(sys.argv[1]=='fix') if len(sys.argv)>1 else test(False)
print("ok")
