import sys; sys.path.insert(0, sys.argv[1] if len(sys.argv)>1 else '.')
import port
b=port.Backend(fixed=('--fixed' in sys.argv))
b.select(['A','B'])
for _ in range(10): b.sample('A',7000)
for _ in range(10): b.sample('B',5800)
print('before deselect: room',b.room(),'B applied',b.com.sessions['B'].applied)
b.select(['B'])
print('after deselect:  room',b.room(),'B settled',b.crd.settledLeadMs('B'),'B applied',b.com.sessions['B'].applied)
assert b.com.sessions['B'].applied==0, f"FAIL: B keeps stale feed delay {b.com.sessions['B'].applied} ms (expected 0)"
print('PASS')
