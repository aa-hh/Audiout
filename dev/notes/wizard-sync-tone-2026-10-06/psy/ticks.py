exec(open("psy/metrics.py").read().split("sig = {")[0])
from mosqito import loudness_zwtv
def train(x):
    y=np.zeros(int(fs*1.6))
    for i in range(4): y[int((0.1+0.35*i)*fs):int((0.1+0.35*i)*fs)+len(x)]+=x
    return y
def nmax(x): return np.max(loudness_zwtv(train(x),fs,field_type="free")[0])
b=tick(1800,2900); l=tick(900,1450)
nb,nl=nmax(b),nmax(l); print(f"peak loudness bright {nb:.2f} sone, low {nl:.2f} sone, ratio {nb/nl:.3f}")
# find gain on bright that matches low
g=1.0
for _ in range(8): g*= (nl/nmax(b*g))**(1/0.6)
print(f"bright gain for equal ISO 532-1 peak loudness: x{g:.3f} ({20*np.log10(g):+.2f} dB); code uses x0.863 (-1.28 dB)")
for f0 in (523.25,783.99):
    m=mallet(f0)[:int(0.3*fs)]; print(f"marimba-like {f0:.0f} Hz, same peak amplitude 0.35: peak loudness {nmax(m):.2f} sone")
