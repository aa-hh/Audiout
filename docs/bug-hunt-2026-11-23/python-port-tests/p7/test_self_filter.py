import sys, port
port.FIXED = "--fixed" in sys.argv
d = port.NativeDiscovery("my-mac.local")
r = []
for st, name in (("airplay", "My Mac"), ("raop", "AABBCCDDEEFF@My Mac")):
    s = port.probe_ipv4_first_emit(name, "192.168.1.20", 7000, {"deviceid": "AA:BB:CC:DD:EE:FF"}, st)
    r.append(d.handle_resolve(s))
ok = r == ["dropped", "dropped"]
print(("PASS" if ok else "FAIL") + f": self receiver results={r}, expected both dropped")
sys.exit(0 if ok else 1)
