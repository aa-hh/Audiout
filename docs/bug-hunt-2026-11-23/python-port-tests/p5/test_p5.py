import sys, port
port.FIX = len(sys.argv)>1 and sys.argv[1]=='fix'
port.FakeTap.built=[]
w=port.World(); c=port.Coord(w, fire_first=True)
c.start('com.x')
sl=c.slots['com.x']
print('state',sl.state,'tap device',sl.tap.device,'default',w.device,'pending',sl.co.pending)
ok = sl.tap.device==w.device and not sl.co.pending
print('PASS' if ok else 'FAIL: device change during initial start lost; tap pinned to stale device')
sys.exit(0 if ok else 1)
