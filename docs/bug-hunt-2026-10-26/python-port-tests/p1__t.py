def swift_current(i): return "iTunes_Ctrl_%016X" % i
def c_header(i): return "%X" % i   # PRIX64 unpadded (per code comment; C source not in copy)
def fixed(i): return "iTunes_Ctrl_%X" % i
i=0x00001A2B3C4D5E6F
for f in (swift_current,fixed):
    print(f.__name__, f(i)=="iTunes_Ctrl_"+c_header(i))
assert swift_current(i)=="iTunes_Ctrl_"+c_header(i), "mismatch"
