exec(open("psy/metrics.py").read().split("sig = {")[0])
from mosqito import loudness_zwtv, sharpness_din_from_loudness, roughness_dw
def rms_norm(x, ref=0.175/np.sqrt(2)): return x*ref/np.sqrt(np.mean(x[np.abs(x)>0]**2))
def pn(lo,hi): return rms_norm(whoosh(lo,hi))
cands = {
 "CURRENT: up 3.2-10k + 0.5 x down 2k-0.5k": sweep(3200,10000)+0.5*sweep(2000,500),
 "sweeps: up 1.6-4.5k + 0.5 x down 1.2k-0.3k": sweep(1600,4500)+0.5*sweep(1200,300),
 "pink noise lanes 1.5-4.5k + 0.5 x 0.3-1.1k": pn(1500,4500)+0.5*pn(300,1100),
 "pink noise lanes 3.2-10k + 0.5 x 0.5-2k": pn(3200,10000)+0.5*pn(500,2000),
 "one pink noise 300-4000 (single lane ref)": pn(300,4000),
}
print(f"{'signal':46s} {'SPL':>5s} {'N5':>6s} {'S':>5s} {'R':>6s} {'PA':>6s}")
for k,x in cands.items():
    xp=pad(x); N,Nsp,b,t=loudness_zwtv(xp,fs,field_type="free")
    S=np.asarray(sharpness_din_from_loudness(N,Nsp,weighting="din")); m=N>0.2*N.max()
    Sw=np.sum(S[m]*N[m])/np.sum(N[m]); N5=np.percentile(N,95)
    R=np.mean(roughness_dw(xp,fs,overlap=0.5)[0])
    wS=(Sw-1.75)*0.25*np.log10(N5+10) if Sw>1.75 else 0
    wFR=2.18/N5**0.4*(0.6*R)  # F (fluctuation strength) taken as 0: single 1 s swell, no 1-20 Hz modulation
    PA=N5*(1+np.sqrt(wS**2+wFR**2))
    spl=20*np.log10(np.sqrt(np.mean(x**2))/2e-5)
    print(f"{k:46s} {spl:5.1f} {N5:6.1f} {Sw:5.2f} {R:6.3f} {PA:6.1f}  (PA/N5 = {PA/N5:4.2f})")
# loudness-matched comparison: scale each so N5 = 10 sone, then PA
print("\nEach scaled to the same loudness (N5 = 10 sone), so PA differences come only from sharpness/roughness:")
for k,x in cands.items():
    g=1.0
    for _ in range(6):
        N=loudness_zwtv(pad(x*g),fs,field_type="free")[0]; N5=np.percentile(N,95); g*= (10/N5)**(1/0.6)
    xp=pad(x*g); N,Nsp,b,t=loudness_zwtv(xp,fs,field_type="free")
    S=np.asarray(sharpness_din_from_loudness(N,Nsp,weighting="din")); m=N>0.2*N.max(); Sw=np.sum(S[m]*N[m])/np.sum(N[m]); N5=np.percentile(N,95)
    wS=(Sw-1.75)*0.25*np.log10(N5+10) if Sw>1.75 else 0
    spl=20*np.log10(np.sqrt(np.mean((x*g)**2))/2e-5)
    print(f"  {k:46s} SPL needed {spl:5.1f} dB, S {Sw:4.2f}, PA {N5*(1+wS):5.1f}")
