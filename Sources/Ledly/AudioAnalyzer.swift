import Accelerate
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What the music effects see of the audio, refreshed ~50 times a second.
struct AudioLevels {
    static let bandCount = 16

    /// Log-spaced bands from ~40 Hz to ~16 kHz, 0…1 after automatic gain.
    var bands: [Float] = Array(repeating: 0, count: bandCount)
    /// Overall loudness, 0…1.
    var level: Float = 0
    /// Low end (kick drum, bass), 0…1.
    var bass: Float = 0
    /// Time of the last detected beat.
    var lastBeat: Date = .distantPast
    /// Same bands per channel (mono sources give the same values on both).
    var leftBands: [Float] = Array(repeating: 0, count: bandCount)
    var rightBands: [Float] = Array(repeating: 0, count: bandCount)
    var leftLevel: Float = 0
    var rightLevel: Float = 0

    static let silent = AudioLevels()

    /// Fake but plausible levels for the effect previews in the window.
    static func demo(time: Double) -> AudioLevels {
        var a = AudioLevels()
        let beatPhase = (time * 2).truncatingRemainder(dividingBy: 1)   // 120 bpm
        let kick = Float(max(0, 1 - beatPhase * 3))
        for i in 0..<bandCount {
            let x = Float(i) / Float(bandCount)
            let wobble = Float(0.5 + 0.5 * sin(time * (2 + Double(i) * 0.7) + Double(i)))
            a.bands[i] = min(1, (1 - x) * kick * 0.9 + wobble * 0.45 * (1 - x * 0.4))
        }
        a.bass = kick
        a.level = 0.4 + 0.4 * kick
        // Slightly different channels so the stereo layout shows something.
        a.leftBands = a.bands.enumerated().map { min(1, $0.element * Float(0.8 + 0.2 * sin(time * 1.3 + Double($0.offset)))) }
        a.rightBands = a.bands.enumerated().map { min(1, $0.element * Float(0.8 + 0.2 * cos(time * 1.1 + Double($0.offset)))) }
        a.leftLevel = a.level * Float(0.85 + 0.15 * sin(time * 1.3))
        a.rightLevel = a.level * Float(0.85 + 0.15 * cos(time * 1.1))
        a.lastBeat = Date().addingTimeInterval(-beatPhase / 2)
        return a
    }
}

/// Captures the system audio with ScreenCaptureKit and turns it into `AudioLevels`.
/// Uses the Screen Recording permission; no extra driver.
final class AudioAnalyzer: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let fftSize = 1024
    private static let sampleRate = 48_000.0

    private let queue = DispatchQueue(label: "ledly.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var starting = false
    private var levels = AudioLevels()

    // Analysis state (audio queue only).
    /// Last `fftSize` samples of each channel (left, right).
    private var rings = [[Float]](repeating: [Float](repeating: 0, count: fftSize), count: 2)
    private var ringIndex = 0
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(fftSize))), radix: .radix2, ofType: DSPSplitComplex.self)!
    private let bandEdges: [Int]
    /// Slowly decaying peak per band: the automatic gain.
    private var peaks = [Float](repeating: 1e-4, count: AudioLevels.bandCount)
    private var levelPeak: Float = 1e-4
    private var bassHistory: [Float] = []

    var isRunning: Bool { stream != nil || starting }

    override init() {
        // FFT bin index where each band starts, log-spaced 40 Hz … 16 kHz.
        let binHz = Self.sampleRate / Double(Self.fftSize)
        var edges: [Int] = []
        for i in 0...AudioLevels.bandCount {
            let hz = 40 * pow(16_000 / 40, Double(i) / Double(AudioLevels.bandCount))
            edges.append(max(1, Int((hz / binHz).rounded())))
        }
        // At least one bin per band.
        for i in 1..<edges.count where edges[i] <= edges[i - 1] { edges[i] = edges[i - 1] + 1 }
        bandEdges = edges
        super.init()
    }

    /// Latest levels (any thread).
    func current() -> AudioLevels {
        lock.lock()
        defer { lock.unlock() }
        return levels
    }

    func start() {
        guard stream == nil, !starting, CGPreflightScreenCaptureAccess() else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else { return }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = Int(Self.sampleRate)
                config.channelCount = 2
                // Video can't be turned off: keep it tiny and slow, and don't add a video output.
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
            } catch {
                NSLog("Ledly: audio capture failed: \(error)")
            }
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
        lock.lock()
        levels = AudioLevels()
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        var blockBuffer: CMBlockBuffer?
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { list.unsafeMutablePointer.deallocate() }
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr else { return }

        // ScreenCaptureKit delivers non-interleaved Float32: one buffer per channel.
        let channels = list.compactMap { buffer -> UnsafeBufferPointer<Float>? in
            guard let data = buffer.mData else { return nil }
            return UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                       count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        }
        guard let left = channels.first, let frames = channels.map(\.count).min(), frames > 0 else { return }
        let right = channels.count > 1 ? channels[1] : left
        for f in 0..<frames {
            rings[0][ringIndex] = left[f]
            rings[1][ringIndex] = right[f]
            ringIndex = (ringIndex + 1) % Self.fftSize
        }
        analyze()
    }

    /// Windowed FFT magnitudes and RMS of one channel's ring.
    private func spectrum(_ ring: [Float]) -> (magnitudes: [Float], rms: Float) {
        let n = Self.fftSize
        // Oldest → newest, windowed.
        var samples = Array(ring[ringIndex...] + ring[..<ringIndex])
        let rms = vDSP.rootMeanSquare(samples)
        vDSP.multiply(samples, window, result: &samples)
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var magnitudes = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                samples.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }
        return (magnitudes, rms)
    }

    private func analyze() {
        let n = Self.fftSize
        let (leftMagnitudes, leftRMS) = spectrum(rings[0])
        let (rightMagnitudes, rightRMS) = spectrum(rings[1])
        let rms = (leftRMS + rightRMS) / 2
        let silent = rms < 1e-4   // nothing playing: don't let the gain blow up the noise floor

        var bands = [Float](repeating: 0, count: AudioLevels.bandCount)
        var leftBands = bands, rightBands = bands
        for b in 0..<AudioLevels.bandCount where !silent {
            let lo = min(bandEdges[b], n / 2 - 1), hi = min(max(bandEdges[b + 1], lo + 1), n / 2)
            let l = leftMagnitudes[lo..<hi].reduce(0, +) / Float(hi - lo)
            let r = rightMagnitudes[lo..<hi].reduce(0, +) / Float(hi - lo)
            // Automatic gain: compare with a peak that decays over ~10 s, shared by both channels
            // so they stay comparable.
            peaks[b] = max(l, r, peaks[b] * 0.9985, 1e-4)
            // A square root reads closer to how loud it sounds than the raw magnitude.
            leftBands[b] = min(1, sqrt(l / peaks[b]))
            rightBands[b] = min(1, sqrt(r / peaks[b]))
            bands[b] = min(1, sqrt((l + r) / 2 / peaks[b]))
        }
        levelPeak = max(leftRMS, rightRMS, levelPeak * 0.999, 1e-4)
        let level = silent ? 0 : min(1, rms / levelPeak)
        let bass = (bands[0] + bands[1] + bands[2] + bands[3]) / 4

        // Beat: bass well above its recent average.
        bassHistory.append(bass)
        if bassHistory.count > 40 { bassHistory.removeFirst() }
        let average = bassHistory.reduce(0, +) / Float(bassHistory.count)

        lock.lock()
        levels.bands = bands
        levels.leftBands = leftBands
        levels.rightBands = rightBands
        levels.leftLevel = silent ? 0 : min(1, leftRMS / levelPeak)
        levels.rightLevel = silent ? 0 : min(1, rightRMS / levelPeak)
        levels.level = level
        levels.bass = bass
        if bass > 0.3, bass > average * 1.35, Date().timeIntervalSince(levels.lastBeat) > 0.25 {
            levels.lastBeat = Date()
        }
        lock.unlock()
    }
}
