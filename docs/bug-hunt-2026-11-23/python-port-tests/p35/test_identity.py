import sys
FIX = '--fix' in sys.argv
def parseDeviceID(txt):
    s = txt.get("deviceid", txt.get("DeviceID"))
    if s is None: return None
    h = s.replace(":", "")
    try: v = int(h, 16)
    except ValueError: return None
    if v >= 2**64 or h == "" or h.startswith(('+','-')): return None
    if FIX and len(h) == 12:
        u = h.upper(); return (":".join(u[i:i+2] for i in range(0,12,2)), v)
    return (s, v)
def derive(name):
    p = name.split("@",1)[0]
    if len(p)!=12 or not all(c in "0123456789abcdefABCDEF" for c in p): return None
    u=p.upper(); return (":".join(u[i:i+2] for i in range(0,12,2)), int(p,16))
def identity(name, txt):
    return parseDeviceID(txt) or derive(name)
known = {}
def resolve(name, stype, txt):  # handleResolve: known keyed on identity id
    r = identity(name, txt)
    if r is None: return
    known.setdefault(r[0], set()).add(stype)
resolve("Kitchen", "airplay", {"deviceid": "aa:bb:cc:dd:ee:ff"})
resolve("AABBCCDDEEFF@Kitchen", "raop", {})
print("known:", known)
assert len(known) == 1, f"FAIL: one device split into {len(known)} known entries"
print("PASS")
