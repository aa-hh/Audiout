# Port of DACPRequest.parse query loop. Swift split(omittingEmptySubsequences=true) emulated.
def swift_split(s, sep, max_splits=None):
    out=[]; cur=""; n=0
    for ch in s:
        if ch==sep and (max_splits is None or n<max_splits):
            n+=1
            if cur: out.append(cur)
            cur=""
        else: cur+=ch
    if cur: out.append(cur)
    return out
def parse_query(qs, fixed=False):
    q={}
    for pair in swift_split(qs,"&"):
        kv=swift_split(pair,"=",1)
        if fixed and not kv: continue
        key=kv[0]  # IndexError == Swift trap
        q[key]=kv[1] if len(kv)>1 else ""
    return q
import sys
fixed=len(sys.argv)>1
for qs in ["=","a&=&b"]:
    parse_query(qs,fixed)
print("ok")
