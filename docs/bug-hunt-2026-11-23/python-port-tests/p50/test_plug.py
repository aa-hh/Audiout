import sys; from port import *
def run(fixed):
    h=HAL(); SPK,HP=1,2
    h.vol={SPK:30,HP:80}; h.mute={SPK:False,HP:False}; h.default=SPK
    o=SystemOutputVolume(h,fixed); o.start()
    # Plug headphones: old speaker device fires a volume/mute notification and the
    # system object fires default-changed; HAL order not guaranteed -> device first.
    h.default=HP
    h.notify_dev(SPK)
    h.notify_default()
    h.drain()
    return o.fired
for fixed in (False,True):
    f=run(fixed); gest=[e for e in f if e[2] is False]
    print("fixed" if fixed else "current", f)
    ok = not gest
    print("PASS" if ok else "FAIL: headphone level reported as gesture (defaultDeviceChanged:false):", gest)
    if not fixed and ok: sys.exit(2)
    if fixed and not ok: sys.exit(1)
