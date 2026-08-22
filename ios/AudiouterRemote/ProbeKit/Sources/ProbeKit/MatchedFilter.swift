import Accelerate
import Foundation

/// Cross-correlates a recording against the tick template with PHAT-style
/// spectral whitening.
///
/// Plain matched filtering against this tick would smear: the tick is two
/// lightly-damped partials, so its autocorrelation has a ~20 ms envelope and a
/// reflection landing 8 ms later merges into the same hump. Whitening the
/// cross-spectrum flattens that envelope towards an impulse, which is what lets
/// the picker separate the direct path from its first reflection.
///
/// Whitening is regularized (`whiteningExponent` < 1, plus a floor tied to the
/// mean bin magnitude) rather than textbook full PHAT: full whitening also
/// lifts the bins where the tick has no energy at all, and a phone mic's noise
/// floor there is pure nuisance.
///
/// It is also SMOOTHED across frequency, which matters more than it looks. The
/// probe is a periodic tick train, so its spectrum is a comb with teeth every
/// 1 / beat period (~1.2 Hz). Whitening bin-by-bin flattens those teeth too,
/// and a flattened comb inverse-transforms into an ENDLESS tick train: ghost
/// peaks a beat outside every block, strong enough to bridge the gaps and weld
/// two blocks into one. Smoothing the denominator over a band far wider than
/// the comb spacing leaves that structure alone, while still flattening what
/// whitening is for here — the ~125 Hz-scale ripple an 8 ms reflection puts on
/// the spectrum.
struct MatchedFilter {

    /// 1 = textbook PHAT, 0 = plain matched filter.
    static let whiteningExponent: Float = 0.75
    /// Denominator floor, as a fraction of the mean cross-spectrum magnitude.
    static let whiteningFloorFraction: Float = 0.05
    /// Width of the frequency smoothing applied to the whitening denominator.
    /// Well above the ~1.2 Hz tick comb, well below a reflection's ripple.
    static let whiteningSmoothingHz = 30.0

    let template: [Float]
    let sampleRate: Double

    /// Correlation magnitude per lag: index *n* scores "a tick started at
    /// sample *n*". One value per candidate start sample.
    func correlationMagnitudes(of recording: [Float]) -> [Float] {
        let lagCount = recording.count - template.count
        guard lagCount > 0, !template.isEmpty else { return [] }

        // Zero-padded to a power of two so the circular correlation the FFT
        // computes has no wraparound within the lags we read back.
        let padded = 1 << Int(ceil(log2(Double(recording.count + template.count))))
        guard let fft = RealFFT(length: padded) else { return [] }

        var signal = fft.forward(zeroPadded(recording, to: padded))
        let kernel = fft.forward(zeroPadded(template, to: padded))
        whiten(&signal, against: kernel)

        let correlation = fft.inverse(real: signal.real, imaginary: signal.imaginary)
        return vDSP.absolute(correlation[0..<lagCount])
    }

    /// Turns the signal spectrum into the whitened cross-spectrum
    /// `signal × conj(kernel)`, in place.
    private func whiten(_ signal: inout (real: [Float], imaginary: [Float]),
                        against kernel: (real: [Float], imaginary: [Float])) {
        let bins = signal.real.count
        var magnitudes = [Float](repeating: 0, count: bins)
        for bin in 0..<bins {
            // Bin 0 is the packed pair (DC, Nyquist): two real terms, no
            // conjugate to take.
            let real = bin == 0
                ? signal.real[0] * kernel.real[0]
                : signal.real[bin] * kernel.real[bin] + signal.imaginary[bin] * kernel.imaginary[bin]
            let imaginary = bin == 0
                ? signal.imaginary[0] * kernel.imaginary[0]
                : signal.imaginary[bin] * kernel.real[bin] - signal.real[bin] * kernel.imaginary[bin]
            signal.real[bin] = real
            signal.imaginary[bin] = imaginary
            magnitudes[bin] = bin == 0
                ? max(abs(real), abs(imaginary))
                : (real * real + imaginary * imaginary).squareRoot()
        }
        let floorValue = vDSP.mean(magnitudes) * Self.whiteningFloorFraction
        let smoothed = smoothedAcrossFrequency(magnitudes)
        for bin in 0..<bins {
            let weight = 1 / pow(smoothed[bin] + floorValue, Self.whiteningExponent)
            signal.real[bin] *= weight
            signal.imaginary[bin] *= weight
        }
    }

    /// Moving average over a `whiteningSmoothingHz`-wide band.
    private func smoothedAcrossFrequency(_ magnitudes: [Float]) -> [Float] {
        let binWidth = sampleRate / Double(magnitudes.count * 2)
        let half = max(1, Int(Self.whiteningSmoothingHz / binWidth) / 2)
        guard half < magnitudes.count / 2 else { return magnitudes }

        var running: Float = magnitudes[0..<half].reduce(0, +)
        var smoothed = [Float](repeating: 0, count: magnitudes.count)
        for bin in magnitudes.indices {
            let entering = bin + half, leaving = bin - half - 1
            if entering < magnitudes.count { running += magnitudes[entering] }
            if leaving >= 0 { running -= magnitudes[leaving] }
            let width = min(magnitudes.count - 1, bin + half) - max(0, bin - half) + 1
            smoothed[bin] = running / Float(width)
        }
        return smoothed
    }

    private func zeroPadded(_ values: [Float], to length: Int) -> [Float] {
        var padded = [Float](repeating: 0, count: length)
        padded.replaceSubrange(0..<values.count, with: values)
        return padded
    }
}

// MARK: - Real FFT

/// vDSP's real-to-complex FFT, in the packing it actually uses: a real signal
/// of `length` samples goes in as `length / 2` split-complex elements (even
/// samples in `real`, odd in `imaginary`), and the spectrum comes back in the
/// same shape with bin 0 carrying DC in `real` and Nyquist in `imaginary`.
///
/// Unnormalized in both directions — only relative magnitudes and peak
/// positions matter downstream.
private struct RealFFT {
    let length: Int
    let bins: Int
    private let setup: vDSP.FFT<DSPSplitComplex>

    init?(length: Int) {
        guard length >= 16, length.nonzeroBitCount == 1 else { return nil }
        guard let setup = vDSP.FFT(log2n: vDSP_Length(length.trailingZeroBitCount),
                                   radix: .radix2,
                                   ofType: DSPSplitComplex.self) else { return nil }
        self.length = length
        self.bins = length / 2
        self.setup = setup
    }

    func forward(_ signal: [Float]) -> (real: [Float], imaginary: [Float]) {
        var real = [Float](repeating: 0, count: bins)
        var imaginary = [Float](repeating: 0, count: bins)
        signal.withUnsafeBufferPointer { source in
            source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { interleaved in
                withSplitComplex(&real, &imaginary) { split in
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(bins))
                }
            }
        }
        return transform(real: real, imaginary: imaginary, forward: true)
    }

    func inverse(real: [Float], imaginary: [Float]) -> [Float] {
        var spectrum = transform(real: real, imaginary: imaginary, forward: false)
        var signal = [Float](repeating: 0, count: length)
        signal.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { interleaved in
                withSplitComplex(&spectrum.real, &spectrum.imaginary) { split in
                    vDSP_ztoc(&split, 1, interleaved, 2, vDSP_Length(bins))
                }
            }
        }
        return signal
    }

    private func transform(real: [Float],
                           imaginary: [Float],
                           forward: Bool) -> (real: [Float], imaginary: [Float]) {
        var inputReal = real
        var inputImaginary = imaginary
        var outputReal = [Float](repeating: 0, count: bins)
        var outputImaginary = [Float](repeating: 0, count: bins)
        withSplitComplex(&inputReal, &inputImaginary) { input in
            withSplitComplex(&outputReal, &outputImaginary) { output in
                if forward {
                    setup.forward(input: input, output: &output)
                } else {
                    setup.inverse(input: input, output: &output)
                }
            }
        }
        return (outputReal, outputImaginary)
    }
}

/// Lends two Float arrays to a body as one `DSPSplitComplex`.
private func withSplitComplex<R>(_ real: inout [Float],
                                 _ imaginary: inout [Float],
                                 _ body: (inout DSPSplitComplex) -> R) -> R {
    real.withUnsafeMutableBufferPointer { realPointer in
        imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
            var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                        imagp: imaginaryPointer.baseAddress!)
            return body(&split)
        }
    }
}
