import Accelerate
import Foundation

let fs = 48000.0
let N = 48000
var rng = SystemRandomNumberGenerator()
struct LCG { var s: UInt64; mutating func g() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } ; mutating func gauss() -> Double { let u1 = max(g(),1e-12), u2 = g(); return sqrt(-2*log(u1))*cos(2*Double.pi*u2) } }
var lcg = LCG(s: 42)

func fadeRC(_ x: inout [Double], _ fade: Double) {
  let f = Int(fade*fs)
  for i in 0..<min(f, x.count) { let w = 0.5-0.5*cos(Double.pi*Double(i)/Double(f)); x[i]*=w; x[x.count-1-i]*=w }
}
func ess(_ f0: Double, _ f1: Double, _ T: Double = 1.0) -> [Double] {
  let n = Int(T*fs); let L = log(f1/f0); let k = 2*Double.pi*f0*T/L
  var x = (0..<n).map { i -> Double in let t = Double(i)/fs; return sin(k*(exp(t/T*L)-1)) }
  fadeRC(&x, 0.08); return x
}
func lin(_ f0: Double, _ f1: Double, _ T: Double = 1.0) -> [Double] {
  let n = Int(T*fs)
  var x = (0..<n).map { i -> Double in let t = Double(i)/fs; return sin(2*Double.pi*(f0*t + (f1-f0)*t*t/(2*T))) }
  fadeRC(&x, 0.08); return x
}
// stepped sweep: frequency held per step, phase continuous; steps = list of freqs over T
func stepped(_ freqs: [Double], _ T: Double = 1.0, gapFade: Double = 0) -> [Double] {
  let n = Int(T*fs); let per = n / freqs.count
  var x = [Double](repeating: 0, count: n); var ph = 0.0
  for i in 0..<n { let s = min(i/per, freqs.count-1); ph += 2*Double.pi*freqs[s]/fs; x[i] = sin(ph)
    if gapFade > 0 { let j = i - s*per; let g = Int(gapFade*fs); var w = 1.0
      if j < g { w = 0.5-0.5*cos(Double.pi*Double(j)/Double(g)) }
      if per-1-j < g { w = 0.5-0.5*cos(Double.pi*Double(per-1-j)/Double(g)) }
      x[i] *= w } }
  fadeRC(&x, 0.08); return x
}
func scale(_ f0: Double, _ f1: Double, _ semis: [Int]) -> [Double] {
  var out: [Double] = []; var oct = 0
  while true { for s in semis { let f = f0*pow(2, Double(s+12*oct)/12); if f > f1*1.0001 { return out }; out.append(f) }; oct += 1 }
}
// plucked notes: onsets, harmonics up to maxHz
func plucks(_ notes: [Double], spacing: Double, T: Double = 1.0, maxHz: Double = 24000, tau: Double = 0.15, inharm: [Double]? = nil) -> [Double] {
  let n = Int(T*fs); var x = [Double](repeating: 0, count: n)
  for (j, f) in notes.enumerated() {
    let on = Int(Double(j)*spacing*fs)
    let partials = inharm ?? (1...8).map { Double($0) }
    for (hi, h) in partials.enumerated() { let fh = f*h; if fh > maxHz { continue }
      let a = 1.0/Double(hi+1); let th = tau/Double(hi+1)
      for i in on..<n { let t = Double(i-on)/fs; let att = min(1, t/0.003); x[i] += a*att*exp(-t/th)*sin(2*Double.pi*fh*t) } }
  }
  fadeRC(&x, 0.005); return x
}
func glides(_ notes: [Double], spacing: Double, T: Double = 1.0, tau: Double = 0.15, bend: Double = 0.03) -> [Double] {
  let n = Int(T*fs); var x = [Double](repeating: 0, count: n)
  for (j, f) in notes.enumerated() { let on = Int(Double(j)*spacing*fs)
    for h in 1...4 { var ph = 0.0
      for i in on..<n { let t = Double(i-on)/fs; let fi = f*Double(h)*pow(2, min(t,bend)/bend/12); ph += 2*Double.pi*fi/fs
        x[i] += (1.0/Double(h))*min(1,t/0.003)*exp(-t/(tau/Double(h)))*sin(ph) } } }
  fadeRC(&x, 0.005); return x
}
func bandMask(_ x: [Double], _ lo: Double, _ hi: Double) -> [Double] {
  // FFT mask via DFT of length pow2
  var n = 16; while n < x.count*2 { n <<= 1 }
  let fwd = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
  let inv = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Double.self)!
  var re = [Double](repeating: 0, count: n), im = re; let z = re
  fwd.transform(inputReal: x + [Double](repeating: 0, count: n-x.count), inputImaginary: z, outputReal: &re, outputImaginary: &im)
  for k in 0..<n { let hz = Double(min(k, n-k))*fs/Double(n); if hz < lo || hz > hi { re[k]=0; im[k]=0 } }
  var ore = z, oim = z; inv.transform(inputReal: re, inputImaginary: im, outputReal: &ore, outputImaginary: &oim)
  return Array(ore.prefix(x.count)).map { $0/Double(n) }
}
func noise(_ T: Double = 1.0) -> [Double] { (0..<Int(T*fs)).map { _ in lcg.gauss() } }
func hann(_ x: [Double]) -> [Double] { let n = x.count; return x.enumerated().map { $0.element*(0.5-0.5*cos(2*Double.pi*Double($0.offset)/Double(n-1))) } }
func pink(_ T: Double = 1.0) -> [Double] { // Voss-McCartney-ish via 1/f spectral shaping
  let w = noise(T); var n = 16; while n < w.count*2 { n <<= 1 }
  let fwd = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
  let inv = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Double.self)!
  var re = [Double](repeating: 0, count: n), im = re; let z = re
  fwd.transform(inputReal: w + [Double](repeating: 0, count: n-w.count), inputImaginary: z, outputReal: &re, outputImaginary: &im)
  for k in 1..<n { let hz = Double(min(k, n-k))*fs/Double(n); let g = 1/sqrt(max(hz,1)); re[k]*=g; im[k]*=g }
  var ore = z, oim = z; inv.transform(inputReal: re, inputImaginary: im, outputReal: &ore, outputImaginary: &oim)
  return Array(ore.prefix(w.count))
}
func schroeder(_ f0: Double, _ lo: Double, _ hi: Double, _ T: Double = 1.0) -> [Double] {
  let ks = Array(Int(ceil(lo/f0))...Int(floor(hi/f0))); let K = Double(ks.count)
  var x = [Double](repeating: 0, count: Int(T*fs))
  for (m, k) in ks.enumerated() { let ph = -Double.pi*Double(m)*Double(m+1)/K
    for i in 0..<x.count { x[i] += cos(2*Double.pi*f0*Double(k)*Double(i)/fs + ph) } }
  fadeRC(&x, 0.08); return x
}
// moving-resonator whoosh: noise through a time-varying 2-pole bandpass, centre sweeps lo->hi exponentially, Hann envelope
func whoosh(_ lo: Double, _ hi: Double, Q: Double = 2, _ T: Double = 1.0) -> [Double] {
  let w = noise(T); var y = [Double](repeating: 0, count: w.count); var y1 = 0.0, y2 = 0.0, x1 = 0.0, x2 = 0.0
  for i in 0..<w.count { let t = Double(i)/Double(w.count); let fc = lo*pow(hi/lo, t)
    let w0 = 2*Double.pi*fc/fs; let al = sin(w0)/(2*Q); let a0 = 1+al
    let b0 = al/a0, b2 = -al/a0, a1 = -2*cos(w0)/a0, a2 = (1-al)/a0
    let v = b0*w[i] + b2*x2 - a1*y1 - a2*y2; x2 = x1; x1 = w[i]; y2 = y1; y1 = v; y[i] = v }
  return hann(bandMask(y, lo, hi))
}
func norm(_ x: [Double]) -> [Double] { let r = sqrt(x.reduce(0){$0+$1*$1}/Double(x.count)); return x.map{$0/r} }

// FFT cross-correlation: corr[lag] = sum rec[lag+i]*probe[i]
func xcorr(_ rec: [Double], _ probe: [Double]) -> [Double] {
  var n = 16; while n < rec.count + probe.count { n <<= 1 }
  let fwd = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
  let inv = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Double.self)!
  let z = [Double](repeating: 0, count: n)
  var ar = z, ai = z, br = z, bi = z
  fwd.transform(inputReal: rec + [Double](repeating: 0, count: n-rec.count), inputImaginary: z, outputReal: &ar, outputImaginary: &ai)
  fwd.transform(inputReal: probe + [Double](repeating: 0, count: n-probe.count), inputImaginary: z, outputReal: &br, outputImaginary: &bi)
  var cr = z, ci = z
  for k in 0..<n { cr[k] = ar[k]*br[k]+ai[k]*bi[k]; ci[k] = ai[k]*br[k]-ar[k]*bi[k] }
  var orr = z, oi = z; inv.transform(inputReal: cr, inputImaginary: ci, outputReal: &orr, outputImaginary: &oi)
  return orr.map { $0/Double(n) }
}
// autocorrelation metrics: two-sided lags via placing probe in middle of zero pad
func acMetrics(_ s: [Double]) -> (w3: Double, side03: Double, side3: Double, sideAt: Double) {
  let pad = 24000; let rec = [Double](repeating: 0, count: pad) + s + [Double](repeating: 0, count: pad)
  let c = xcorr(rec, s); let center = pad; let pk = c[center]
  // envelope width via -3 dB of |c| local maxima: use sampled |c| hull approx: max over +-carrier window
  // analytic-signal envelope of the correlation over +-0.5 s
  let W = 24000; let seg = Array(c[(center-W)...(center+W)])
  var n = 16; while n < seg.count { n <<= 1 }
  let fwd = vDSP.DFT(count: n, direction: .forward, transformType: .complexComplex, ofType: Double.self)!
  let inv = vDSP.DFT(count: n, direction: .inverse, transformType: .complexComplex, ofType: Double.self)!
  let z = [Double](repeating: 0, count: n); var re = z, im = z
  fwd.transform(inputReal: seg + [Double](repeating: 0, count: n-seg.count), inputImaginary: z, outputReal: &re, outputImaginary: &im)
  for k in 1..<n { if k < n/2 { re[k]*=2; im[k]*=2 } else if k > n/2 { re[k]=0; im[k]=0 } }
  var ar = z, ai = z; inv.transform(inputReal: re, inputImaginary: im, outputReal: &ar, outputImaginary: &ai)
  let envv = (0..<seg.count).map { sqrt(ar[$0]*ar[$0]+ai[$0]*ai[$0])/Double(n) }
  let ep = envv[W]; var i = W; while i < seg.count-1 && envv[i] > ep/sqrt(2) { i += 1 }
  let w3 = 2*Double(i-W)/fs*1000
  var s03 = 0.0, s3 = 0.0, at = 0.0
  for l in 1..<24000 { let v = max(abs(c[center+l]), abs(c[center-l]))
    if l > Int(0.0003*fs) { if v > s03 { s03 = v } }
    if l > Int(0.003*fs) { if v > s3 { s3 = v; at = Double(l)/fs*1000 } } }
  return (w3, 20*log10(s03/pk), 20*log10(s3/pk), at)
}
// noisy trials: rms timing error (ms) of non-outliers, outlier rate (>1 ms), at given per-sample SNR dB (signal RMS 1, white noise)
func trials(_ s: [Double], snr: Double, n: Int = 60) -> (rms: Double, out1: Double, out5: Double) {
  let sig = sqrt(pow(10, -snr/10)); var errs: [Double] = []; var o1 = 0, o5 = 0
  for _ in 0..<n {
    let off = 6000 + Int(lcg.g()*1000)
    var rec = (0..<(s.count+12000)).map { _ in sig*lcg.gauss() }
    for i in 0..<s.count { rec[off+i] += s[i] }
    let c = xcorr(rec, s); var bi = 0; var bv = -1e300
    for l in 0..<(rec.count-s.count) where c[l] > bv { bv = c[l]; bi = l }
    var o = Double(bi); if bi > 0 { let cm = c[bi-1], c0 = c[bi], cp = c[bi+1]; let d = cm-2*c0+cp; if d < 0 { o += 0.5*(cm-cp)/d } }
    let e = (o - Double(off))/fs*1000
    if abs(e) > 1 { o1 += 1 } ; if abs(e) > 5 { o5 += 1 } else if abs(e) <= 1 { errs.append(e) }
  }
  let r = errs.isEmpty ? .nan : sqrt(errs.reduce(0){$0+$1*$1}/Double(errs.count))
  return (r, Double(o1)/Double(n)*100, Double(o5)/Double(n)*100)
}
func xiso(_ a: [Double], _ bRef: [Double]) -> Double { // leakage of lane a into lane b's matched filter, relative to b's own peak, dB
  let pad = 24000; let rec = [Double](repeating: 0, count: pad) + a + [Double](repeating: 0, count: pad)
  let c = xcorr(rec, bRef); let m = c.map{abs($0)}.max()!
  let rb = [Double](repeating: 0, count: pad) + bRef + [Double](repeating: 0, count: pad)
  let pb = xcorr(rb, bRef)[pad]
  return 20*log10(m/pb)
}
func writeWav(_ x: [Double], _ path: String) {
  let pk = x.map{abs($0)}.max()!; let g = 0.5/pk
  var d = Data(); func u32(_ v: UInt32){ var v=v.littleEndian; d.append(Data(bytes:&v,count:4)) }; func u16(_ v: UInt16){ var v=v.littleEndian; d.append(Data(bytes:&v,count:2)) }
  let pad = 9600; let all = [Double](repeating: 0, count: pad) + x + [Double](repeating: 0, count: pad)
  d.append("RIFF".data(using:.ascii)!); u32(UInt32(36+all.count*2)); d.append("WAVEfmt ".data(using:.ascii)!); u32(16); u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
  d.append("data".data(using:.ascii)!); u32(UInt32(all.count*2)); for v in all { u16(UInt16(bitPattern: Int16(max(-32767,min(32767,v*g*32767))))) }
  try! d.write(to: URL(fileURLWithPath: path))
}
func readWav(_ path: String) -> [Double] { // 16-bit mono PCM, find data chunk
  let d = try! Data(contentsOf: URL(fileURLWithPath: path)); var p = 12
  while p < d.count-8 { let id = String(data: d[p..<p+4], encoding:.ascii)!; let sz = Int(d[p+4]) | Int(d[p+5])<<8 | Int(d[p+6])<<16 | Int(d[p+7])<<24
    if id == "data" { var out: [Double] = []; var q = p+8; while q+1 < min(d.count, p+8+sz) { out.append(Double(Int16(bitPattern: UInt16(d[q]) | UInt16(d[q+1])<<8))/32767); q += 2 }; return out }
    p += 8 + sz + (sz & 1) }
  return []
}
func sh(_ a: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert"); p.arguments = a; try! p.run(); p.waitUntilExit() }

let LO = (500.0, 2000.0), HI = (3200.0, 10000.0)
let semis12 = Array(0..<12)
var sigs: [(String, [Double])] = []
sigs.append(("ESS low 2000->500 (today)", ess(2000, 500)))
sigs.append(("ESS high 3200->10000 (today)", ess(3200, 10000)))
sigs.append(("linear sweep low", lin(500, 2000)))
sigs.append(("stepped: semitones low (24 notes, 42 ms)", stepped(scale(500, 2000, semis12).reversed())))
sigs.append(("stepped: C-major scale low (14 notes)", stepped(scale(523.25, 2000, [0,2,4,5,7,9,11]))))
sigs.append(("stepped: pentatonic low (11 notes)", stepped(scale(523.25, 2000, [0,2,4,7,9]))))
sigs.append(("stepped: 6-note arpeggio, separate beeps", stepped([523.25,659.25,783.99,1046.5,1318.5,1567.98], gapFade: 0.01)))
sigs.append(("plucked arpeggio low, 8 notes, full harmonics", plucks([523.25,659.25,783.99,987.77,1046.5,1318.5,1567.98,1975.5], spacing: 0.11)))
sigs.append(("plucked arpeggio low, band-limited 500-2000", bandMask(plucks([523.25,659.25,783.99,987.77,1046.5,1318.5,1567.98,1975.5], spacing: 0.11), 500, 2000)))
sigs.append(("repeated note x8 (same pitch 784 Hz plucks)", bandMask(plucks(Array(repeating: 783.99, count: 8), spacing: 0.11), 500, 2000)))
sigs.append(("chord stab C-E-G (one hit, 0.6 s ring)", bandMask(plucks([523.25], spacing: 0, tau: 0.25) .enumerated().map{ $0.element } , 500, 2000)))
sigs.append(("Schroeder multisine 50 Hz grid 500-2000", schroeder(50, 500, 2000)))
sigs.append(("Schroeder multisine 10 Hz grid 500-2000", schroeder(10, 500, 2000)))
sigs.append(("band noise burst low, 80 ms fades", { var x = bandMask(noise(), 500, 2000); fadeRC(&x, 0.08); return x }()))
sigs.append(("pink noise burst low, Hann envelope", hann(bandMask(pink(), 500, 2000))))
sigs.append(("whoosh low (moving bandpass, Hann)", whoosh(500, 2000)))
sigs.append(("whoosh high (moving bandpass, Hann)", whoosh(3200, 10000)))
sigs.append(("band noise high, Hann envelope", hann(bandMask(noise(), 3200, 10000))))
sigs.append(("bells high: 6 inharmonic strikes 3.2-10k", bandMask(plucks([3300,3700,4150,4400,4950,5550], spacing: 0.15, tau: 0.3, inharm: [1, 2.76, 5.40]), 3200, 10000)))
// fix chord: real triad
sigs[10] = ("chord stab C-E-G (one hit, 0.6 s ring)", bandMask({ let a = plucks([523.25], spacing: 0, tau: 0.25); let b = plucks([659.25], spacing: 0, tau: 0.25); let c = plucks([783.99], spacing: 0, tau: 0.25); return (0..<a.count).map{a[$0]+b[$0]+c[$0]} }(), 500, 2000))
sigs.append(("arpeggio of glide-plucks (each note bends up 1 semitone)", bandMask(glides([523.25,659.25,783.99,987.77,1046.5,1318.5,1567.98,1975.5], spacing: 0.11), 500, 2000)))
sigs.append(("arpeggio whole-tone scale plucks (no common period)", bandMask(plucks(scale(523.25, 2000, [0,2,4,6,8,10]).prefix(10).map{$0}, spacing: 0.095), 500, 2000)))
sigs.append(("4 x 0.25 s ESS repeated", { let e = ess(2000, 500, 0.25); return e+e+e+e }()))
sigs.append(("4 x 0.25 s ESS alternating down/up", { let d = ess(2000, 500, 0.25), u = ess(500, 2000, 0.25); return d+u+d+u }()))
sigs.append(("ESS low 0.5 s", ess(2000, 500, 0.5)))
sigs.append(("ESS low 2.0 s", ess(2000, 500, 2.0)))
sigs = sigs.map { ($0.0, norm($0.1)) }

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ac"
if mode == "ac" {
  print("signal | -3dB envelope width ms | max sidelobe >0.3ms dB | max sidelobe >3ms dB @ms | trials SNR-30: rms(us) >1ms% >5ms% | SNR-36 | SNR-40")
  for (name, s) in sigs {
    let m = acMetrics(s); let a = trials(s, snr: -30); let b = trials(s, snr: -36); let c = trials(s, snr: -40)
    print(String(format: "%@ | %.2f | %.1f | %.1f @%.1f | %.0f %.0f %.0f | %.0f %.0f %.0f | %.0f %.0f %.0f", name, m.w3, m.side03, m.side3, m.sideAt, a.rms*1000, a.out1, a.out5, b.rms*1000, b.out1, b.out5, c.rms*1000, c.out1, c.out5))
  }
}
if mode == "iso" {
  let essL = norm(ess(2000,500)), essH = norm(ess(3200,10000)), essUp = norm(ess(500,10000)), essDn = norm(ess(10000,500))
  print("up vs down ESS shared 500-10k band:", xiso(essDn, essUp))
  print("ESS low into ESS high filter (today):", xiso(essL, essH))
  print("ESS high into ESS low filter (today):", xiso(essH, essL))
  let pl = norm(plucks([523.25,659.25,783.99,987.77,1046.5,1318.5,1567.98,1975.5], spacing: 0.11))
  let bells = sigs[18].1
  print("plucks low FULL harmonics into bells-high filter:", xiso(pl, bells))
  print("plucks low band-limited into bells-high filter:", xiso(sigs[8].1, bells))
  print("plucks low band-limited into whoosh-high filter:", xiso(sigs[8].1, sigs[16].1))
  print("whoosh high into plucks-low filter:", xiso(sigs[16].1, sigs[8].1))
  print("whoosh low into whoosh high:", xiso(sigs[15].1, sigs[16].1))
  // abutting bands, no guard
  let a = norm(hann(bandMask(noise(), 500, 3000))), b = norm(hann(bandMask(noise(), 3000, 10000)))
  print("noise 500-3000 into noise 3000-10000 (abutting, FFT-ideal):", xiso(a, b))
  let n1 = norm(hann(bandMask(noise(), 500, 10000))), n2 = norm(hann(bandMask(noise(), 500, 10000)))
  print("two independent noise bursts, same band 500-10k (like two MLS):", xiso(n1, n2))
  let m1 = norm(hann(bandMask(noise(), 3200, 10000))), m2 = norm(hann(bandMask(noise(), 3200, 10000)))
  print("two independent noise bursts, same band 3.2-10k:", xiso(m1, m2))
  // MESM-style: same ESS on both lanes, B delayed by D; leakage of lane A into the window around B
  let e = norm(ess(500, 10000)); let pad = 24000; let rec = [Double](repeating: 0, count: pad) + e + [Double](repeating: 0, count: 3*pad)
  let c = xcorr(rec, e); let pk = c[pad]
  for D in [0.005, 0.02, 0.1, 0.3, 0.6] { let L = pad + Int(D*fs); var m = 0.0; for l in (L-240)...(L+240) { m = max(m, abs(c[l])) }; print(String(format: "same ESS staggered: sidelobe at +%.0f ms (+-5 ms window): %.1f dB", D*1000, 20*log10(m/pk))) }
}
if mode == "codec" {
  print("signal | AAC kbps | shift vs original (us, after removing ESS-low shift) | peak loss dB | residual (decoded-original) dB re signal")
  for kb in [64, 128, 256] {
    var ref: Double? = nil
    for (idx, (name, s)) in sigs.enumerated() where [0,1,8,11,13,15,16,17,18,19].contains(idx) {
      writeWav(s, "in.wav"); sh(["-f","m4af","-d","aac","-b","\(kb*1000)","in.wav","enc.m4a"]); sh(["-f","WAVE","-d","LEI16","enc.m4a","dec.wav"])
      let o = readWav("in.wav"), dd = readWav("dec.wav")
      let c = xcorr(dd, Array(o[9600..<(9600+s.count)])); var bi = 0; var bv = -1e300
      for l in 0..<max(1, dd.count-s.count) where c[l] > bv { bv = c[l]; bi = l }
      var off = Double(bi); let cm = c[bi-1], c0 = c[bi], cp = c[bi+1]; let dn = cm-2*c0+cp; if dn < 0 { off += 0.5*(cm-cp)/dn }
      if ref == nil { ref = off }
      let oc = xcorr(o, Array(o[9600..<(9600+s.count)]))[9600]
      // residual after alignment at integer lag
      let shift = bi - 9600; var e = 0.0, p = 0.0
      for i in 9600..<(9600+s.count) where i+shift < dd.count && i+shift >= 0 { let r = dd[i+shift]-o[i]; e += r*r; p += o[i]*o[i] }
      print(String(format: "%@ | %d | %.1f | %.2f | %.1f", name, kb, (off-ref!)/fs*1e6, 20*log10(bv/oc), 10*log10(e/p)))
    }
  }
}
func conv(_ x: [Double], _ h: [Double]) -> [Double] {
  let c = xcorr(x + [Double](repeating: 0, count: h.count), Array(h.reversed()))
  return (0..<x.count).map { n in n - (h.count-1) >= 0 ? c[n-(h.count-1)] : 0 }
}
if mode == "stag" {
  // room: direct + exponentially decaying noise tail, RT60 0.5 s, reverb energy = -DRR dB re direct
  func room(_ drr: Double) -> [Double] { let n = Int(0.8*fs); var h = [Double](repeating: 0, count: n); h[0] = 1
    var tail = (1..<n).map { i in lcg.gauss()*exp(-6.9*Double(i)/fs/0.5) }; let e = tail.reduce(0){$0+$1*$1}; let g = sqrt(pow(10, -drr/10)/e); tail = tail.map{$0*g}
    for i in 1..<n { h[i] = tail[i-1] }; return h }
  let cands: [(String, [Double])] = [("ESS 500-10k", norm(ess(500, 10000))), ("whoosh 500-10k", norm(whoosh(500, 10000))), ("glide arpeggio + high whoosh (sum)", norm(zip(sigs[19].1, sigs[16].1).map{$0+$1}))]
  print("stimulus | quiet lane placement | gap ms | trials: %err>1ms | median quiet-peak margin over strongest rival in search window (dB)")
  for (name, s) in cands { for before in [true, false] { for gap in [0.15, 0.3, 0.6] {
    var bad = 0; var margins: [Double] = []
    for _ in 0..<20 {
      let loudAt = 60000, quietAt = before ? loudAt - Int(gap*fs) : loudAt + Int(gap*fs)
      let loud = conv(s, room(10)).map { $0 + 0.01*$0*$0*$0 }  // near speaker: DRR +10 dB, mild cubic distortion
      let quiet = conv(s, room(-3)).map { $0 * pow(10, -25.0/20) } // far speaker: DRR -3 dB, -25 dB
      var rec = (0..<(loudAt + s.count + 60000)).map { _ in 0.003*lcg.gauss() }
      for i in 0..<loud.count where loudAt+i < rec.count { rec[loudAt+i] += loud[i] }
      for i in 0..<quiet.count where quietAt+i < rec.count && quietAt+i >= 0 { rec[quietAt+i] += quiet[i] }
      let c = xcorr(rec, s); let lo = quietAt - 4800, hi = quietAt + 4800  // +-100 ms latency uncertainty
      var bi = lo; var bv = -1e300; for l in lo..<hi where c[l] > bv { bv = c[l]; bi = l }
      if abs(bi - quietAt) > 48 { bad += 1 }
      var rv = 0.0; for l in lo..<hi where abs(l - quietAt) > 144 { rv = max(rv, c[l]) }
      margins.append(20*log10(c[quietAt]/rv))
    }
    margins.sort()
    print(String(format: "%@ | %@ | %.0f | %d%% | %.1f", name, before ? "BEFORE loud" : "AFTER loud", gap*1000, bad*5, margins[10]))
  } } }
}
