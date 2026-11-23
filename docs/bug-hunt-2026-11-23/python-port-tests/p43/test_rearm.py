# Port of CastOutputManager session/deadline logic (launch arms deadline, first GET re-arms,
# teardown/startRecipe as in Swift). FIX=1 resets loggedHTTPRequest in teardown.
import os, sys
FIX = os.environ.get("FIX") == "1"
PLAY_DEADLINE = 20  # defaultPlayDeadline
class Session:
    def __init__(s): s.generation=0; s.loggedHTTPRequest=False; s.deadline=None; s.state="idle"
class Mgr:
    def __init__(m): m.s=Session(); m.now=0
    def startRecipe(m): m.s.generation+=1; m.s.state="connecting"
    def teardown(m):
        m.s.deadline=None; m.s.generation+=1
        if FIX: m.s.loggedHTTPRequest=False
    def retry(m): m.teardown(); m.startRecipe()
    def arm(m): m.s.deadline=(m.now+PLAY_DEADLINE, m.s.generation)
    def advance(m,t):
        d=m.s.deadline
        if d and d[0]<=t and d[1]==m.s.generation:
            m.now=d[0]; m.teardown(); m.s.state="failed(timeout)"
        m.now=t
    def afterLaunch(m,t): m.advance(t); m.arm()
    def onRequest(m,t):  # GET
        m.advance(t)
        if m.s.state.startswith("failed"): return
        if m.s.loggedHTTPRequest: return
        m.s.loggedHTTPRequest=True; m.arm()
    def playing(m,t):
        m.advance(t)
        if m.s.state.startswith("failed"): return
        m.s.deadline=None; m.s.state="playing"
def attempt(m, base):
    m.afterLaunch(base+3); m.onRequest(base+15); m.playing(base+25)
m=Mgr(); m.startRecipe(); attempt(m,0)
assert m.s.state=="playing", m.s.state
m.retry()  # user retry(deviceID:)
attempt(m,100)   # launch t=103, GET t=115, PLAYING t=125
print("second attempt state:", m.s.state)
assert m.s.state=="playing", "FAIL: second attempt timed out at t=123 (GET at 115 did not re-arm)"
print("PASS")
