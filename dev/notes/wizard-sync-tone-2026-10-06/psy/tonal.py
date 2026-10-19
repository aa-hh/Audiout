exec(open("psy/metrics.py").read().split("for k,v in sig.items()")[0])
def bark(f): return 13*np.arctan(0.00076*f)+3.5*np.arctan((f/7500)**2)
def onebark_share(x, win=0.02):
    n=int(win*fs); out=[]
    for i in range(0, len(x)-n, n//2):
        s=x[i:i+n]*np.hanning(n); P=np.abs(np.fft.rfft(s, 8*n))**2; f=np.fft.rfftfreq(8*n,1/fs)
        if P.sum() < 1e-9*len(P): continue
        z=bark(f); best=0
        for zc in np.arange(1,24,0.25):
            best=max(best, P[(z>=zc-0.5)&(z<zc+0.5)].sum())
        out.append((best/P.sum(), P.sum()))
    a=np.array(out); w=a[:,1]; return np.sum(a[:,0]*w)/np.sum(w)
allsig = dict(sig); allsig.update({"bright tick 1800+2900": tick(1800,2900), "low tick 900+1450": tick(900,1450),
  "marimba-like C5 523 Hz (300 ms)": mallet(523.25)[:int(0.3*fs)]})
for k,x in allsig.items(): print(f"{k:42s} energy in one critical band: {100*onebark_share(x):5.1f} %")
