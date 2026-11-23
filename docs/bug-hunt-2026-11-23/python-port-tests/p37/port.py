# Faithful port of NativeDiscovery.handleResolve/buildDevice/descriptor(from:)/classify/parseFeatures/identity
import re, sys
FIX = "--fix" in sys.argv
def parseHex32(s):
    s=s.strip()
    if s[:2].lower()=="0x": s=s[2:]
    if not s: return None
    try: v=int(s,16)
    except ValueError: return None
    return v if v<2**32 else None
def parseFeatures(t):
    p=t.split(",",1); lo=parseHex32(p[0])
    if lo is None: return None
    if len(p)==1: return lo
    hi=parseHex32(p[1]); 
    if hi is None: return None
    return lo|(hi<<32)
def classify(a):
    if a is None: return False
    f=a["txt"].get("features") or a["txt"].get("Features")
    f=parseFeatures(f) if f else None
    if f is None: return False
    return (f>>9)&1==1 and any((f>>b)&1 for b in (38,43,46,48))
def derive(name):
    pre=name.split("@",1)[0]
    if len(pre)!=12 or not re.fullmatch(r"[0-9a-fA-F]{12}",pre): return None
    u=pre.upper(); return ":".join(u[i:i+2] for i in range(0,12,2))
def identity(s):
    d=s["txt"].get("deviceid") or s["txt"].get("DeviceID")
    return d if d else derive(s["name"])
def descriptor(s):
    kind="raop" if s["type"]=="raop" else "airplay"
    txt=dict(s["txt"])
    if s["type"]=="raop" and "deviceid" not in txt and "DeviceID" not in txt:
        d=derive(s["name"]); 
        if d: txt["deviceid"]=d
    return {"name":s["name"],"kind":kind,"txt":txt}
def buildDevice(e):
    if FIX:
        src=(e["airplay"] if classify(e["airplay"]) else None) or e["raop"] or e["airplay"]
    else:
        src=e["airplay"] or e["raop"]
    isAP2=e["ever"] or classify(e["airplay"])
    cf=e["ever"] and e["airplay"] is None
    return {"descriptor": e["dev"]["descriptor"] if cf else descriptor(src), "ap2":isAP2}
known={}
def handleResolve(s):
    i=identity(s)
    e=known.get(i) or {"dev":{"descriptor":descriptor(s)},"airplay":None,"raop":None,"ever":False}
    e[s["type"]]=s
    if classify(e["airplay"]): e["ever"]=True
    e["dev"]=buildDevice(e); known[i]=e
    return e["dev"]
handleResolve({"type":"airplay","name":"Living Room","txt":{"deviceid":"58:55:CA:00:11:22","features":"0x5A7FFFF7,0x1E"}})
d=handleResolve({"type":"raop","name":"5855CA001122@Living Room","txt":{}})
print("isAP2=",d["ap2"],"descriptor.kind=",d["descriptor"]["kind"])
assert not d["ap2"]
assert d["descriptor"]["kind"]=="raop", "AP1-only device routed with kind .airplay (to AP2 backend)"
print("PASS")
