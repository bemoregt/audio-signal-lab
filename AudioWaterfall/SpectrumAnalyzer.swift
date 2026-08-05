//
//  SpectrumAnalyzer.swift
//  AudioWaterfall
//

import Accelerate
import AVFoundation

final class SpectrumAnalyzer {
    // Runtime-selectable via the resolution picker (AppViewModel sets this on the main
    // thread while computeSpectrum() reads it from the audio callback thread), so access
    // is guarded by `lock` rather than being a plain stored property.
    private var _visualBinCount = 128
    var visualBinCount: Int {
        get { lock.lock(); defer { lock.unlock() }; return _visualBinCount }
        set { lock.lock(); _visualBinCount = newValue; lock.unlock() }
    }

    // User-toggleable via a checkbox in the UI; same cross-thread access pattern as
    // visualBinCount above.
    private var _logScaleEnabled = true
    var logScaleEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _logScaleEnabled }
        set { lock.lock(); _logScaleEnabled = newValue; lock.unlock() }
    }

    // 4x the previous fftSize (2048->8192) for ~4x real frequency resolution within the
    // 12kHz display range. Trade-off: the FFT window is now ~186ms of audio (was ~46ms),
    // so transient response is a bit less snappy — a fundamental time/frequency-resolution
    // trade-off, not a bug.
    private let fftSize = 8192
    private let hopSize = 4096
    private let sampleRate: Double = 44100
    private let maxFrequency: Double = 6000

    // Adaptive ceiling (auto-gain) instead of a fixed dB range: real sources (quiet mic
    // input vs. loud system audio vs. a file) sit at wildly different absolute levels, so a
    // fixed floor/ceiling either clips everything to blue (ceiling too high) or blows out
    // immediately (too low). Tracking the recent peak keeps color and height meaningful
    // regardless of source.
    private var runningCeilingDB: Float = -50
    private let dynamicRangeDB: Float = 45
    private let peakDecayPerHop: Float = 0.15

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var sampleRing: [Float]
    private var ringWriteIndex = 0
    private var samplesAccumulated = 0
    private var realp: [Float]
    private var imagp: [Float]

    private let lock = NSLock()
    private var latestSpectrum: [Float]?

    init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        sampleRing = [Float](repeating: 0, count: fftSize)
        realp = [Float](repeating: 0, count: fftSize / 2)
        imagp = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Called from whichever audio thread owns the active AudioSource. Only one source runs at a time.
    func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)

        for sample in samples {
            sampleRing[ringWriteIndex] = sample
            ringWriteIndex = (ringWriteIndex + 1) % fftSize
            samplesAccumulated += 1
            if samplesAccumulated >= hopSize {
                samplesAccumulated = 0
                computeSpectrum()
            }
        }
    }

    /// Drains the most recently computed spectrum row, if a new one is available since the last call.
    func consumeLatest() -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        let value = latestSpectrum
        latestSpectrum = nil
        return value
    }

    private func computeSpectrum() {
        var linear = [Float](repeating: 0, count: fftSize)
        for i in 0..<fftSize {
            linear[i] = sampleRing[(ringWriteIndex + i) % fftSize]
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(linear, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var splitComplex = DSPSplitComplex(realp: &realp, imagp: &imagp)
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
            }
        }
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

        var reference = Float(fftSize) * Float(fftSize)
        var dB = [Float](repeating: 0, count: fftSize / 2)
        vDSP_vdbcon(&magnitudes, 1, &reference, &dB, 1, vDSP_Length(fftSize / 2), 1)

        let frameMaxDB = dB.max() ?? runningCeilingDB
        runningCeilingDB = frameMaxDB > runningCeilingDB ? frameMaxDB : max(frameMaxDB, runningCeilingDB - peakDecayPerHop)
        let floorDB = runningCeilingDB - dynamicRangeDB

        let logScaleEnabled = self.logScaleEnabled

        var normalized = [Float](repeating: 0, count: fftSize / 2)
        for i in 0..<dB.count {
            let clamped = min(max(dB[i], floorDB), runningCeilingDB)
            let linear = (clamped - floorDB) / dynamicRangeDB
            // Gamma-boost (log-scale) so moderate signal levels still spread across the full
            // colormap range instead of clustering near the cool end.
            normalized[i] = logScaleEnabled ? sqrt(linear) : linear
        }

        let downsampled = downsample(normalized)

        lock.lock()
        latestSpectrum = downsampled
        lock.unlock()
    }

    /// Proportional (not fixed-stride) linear frequency mapping: when visualBinCount
    /// approaches or exceeds maxBinIndex, a fixed integer stride would silently drop the
    /// upper part of the frequency range instead of spreading all available raw bins
    /// across the outputs.
    private func downsample(_ bins: [Float]) -> [Float] {
        let binCount = visualBinCount
        let nyquist = sampleRate / 2
        let maxBinIndex = min(bins.count, Int(Double(bins.count) * (maxFrequency / nyquist)))
        guard maxBinIndex > 0 else { return [Float](repeating: 0, count: binCount) }

        var result = [Float](repeating: 0, count: binCount)
        for outIdx in 0..<binCount {
            let start = Int(Double(outIdx) * Double(maxBinIndex) / Double(binCount))
            let end = min(maxBinIndex, max(start + 1, Int(Double(outIdx + 1) * Double(maxBinIndex) / Double(binCount))))
            var sum: Float = 0
            for i in start..<end { sum += bins[i] }
            result[outIdx] = sum / Float(end - start)
        }
        return result
    }
}
