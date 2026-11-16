# Faithful port of CompletionRegistry install/uninstall (hook = global C state).
import sys
hook = None  # outputs_engine_completion_set state
def hook_set(h): 
    global hook; hook = h
class Reg:
    shared = None
    def __init__(s,n): s.n=n; s.waiters={}; s.got=[]
    def install(s):
        Reg.shared = s
        hook_set(lambda cid: Reg.shared.waiters.pop(cid)(cid) if Reg.shared and cid in Reg.shared.waiters else None)
    def uninstall(s, fixed=False):
        if not fixed: hook_set(None)
        cancelled=s.waiters; s.waiters={}
        for w in cancelled.values(): w('cancel')
        if Reg.shared is s:
            Reg.shared=None
            if fixed: hook_set(None)
def run(fixed):
    global hook; hook=None; Reg.shared=None
    A,B=Reg('A'),Reg('B'); A.install(); B.install()
    B.waiters[1]=lambda x:B.got.append(x)
    A.uninstall(fixed)
    return hook is not None   # B's hook still live?
if __name__=='__main__':
    ok=run(fixed=(len(sys.argv)>1))
    print('B hook live:',ok); assert ok,"B's hook was unset by A.uninstall()"
