import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What the grabber needs to turn a frame into one color per LED.
struct GrabberConfig: Equatable {
    var displayID: CGDirectDisplayID
    /// Follow this app's largest window instead of the whole display; nil = display.
    var appBundleID: String?
    var fps: Int
    var zones: [CGRect]
    var sampling: SamplingMode
    var blackBorders: Bool
}

/// Captures one screen at low resolution with ScreenCaptureKit and averages each LED zone.
final class ScreenGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Status: Equatable {
        case stopped, starting, running, noPermission, failed(String)
    }

    /// Called on the capture queue with one color per zone.
    var onColors: (([RGB]) -> Void)?
    var onStatus: ((Status) -> Void)?
    /// What is being captured ("Pantalla DELL", "Ventana de Safari…"), on change.
    var onSource: ((String) -> Void)?
    /// A downscaled copy of the frame and the content rect left after cropping black borders
    /// (in the image's pixels), a few times a second while `previewWanted` is on.
    var onPreview: ((CGImage, CGRect) -> Void)?

    /// Set from any thread; only then are preview images made.
    var previewWanted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _previewWanted }
        set { lock.lock(); _previewWanted = newValue; lock.unlock() }
    }
    private var _previewWanted = false
    private var lastPreview = Date.distantPast
    /// Window being captured in app mode, to notice when a different one becomes the main one.
    private var capturedWindow: (id: CGWindowID, size: CGSize)?
    private var appWatch: DispatchSourceTimer?

    private let queue = DispatchQueue(label: "ledly.grabber", qos: .userInteractive)
    private var stream: SCStream?
    private var config: GrabberConfig?
    private var streamKey: (CGDirectDisplayID, Int)?
    private let lock = NSLock()
    private var analysis = FrameAnalyzer()

    private static var didRequestAccess = false

    /// Captured width; tall enough for thin zones, small enough to be cheap.
    private static let captureWidth = 256

    func update(_ newConfig: GrabberConfig?) {
        lock.lock()
        let old = config
        config = newConfig
        lock.unlock()
        guard let newConfig else {
            stop()
            return
        }
        if stream == nil || old?.displayID != newConfig.displayID || old?.fps != newConfig.fps
            || old?.appBundleID != newConfig.appBundleID {
            restart(newConfig)
        }
    }

    /// In app mode, checks every 2 s whether the app's main window changed (another window,
    /// resized, closed, app quit) and restarts the capture on it.
    private func watchApp(_ config: GrabberConfig) {
        appWatch?.cancel()
        appWatch = nil
        guard let bundleID = config.appBundleID else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
                let best = Self.mainWindow(of: bundleID, in: content)
                let current = self.capturedWindow
                let changed: Bool
                switch (best, current) {
                case (nil, nil): changed = false
                case (let w?, let c?): changed = w.windowID != c.id
                    || abs(w.frame.width - c.size.width) > 2 || abs(w.frame.height - c.size.height) > 2
                default: changed = true
                }
                if changed, let config = self.currentConfig(), config.appBundleID == bundleID {
                    self.restart(config)
                }
            }
        }
        timer.resume()
        appWatch = timer
    }

    private func currentConfig() -> GrabberConfig? {
        lock.withLock { config }
    }

    /// The app's largest normal window that's on screen, if any.
    static func mainWindow(of bundleID: String, in content: SCShareableContent) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.isOnScreen
                && $0.windowLayer == 0 && $0.frame.width >= 160 && $0.frame.height >= 120 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func restart(_ config: GrabberConfig) {
        stop()
        onStatus?(.starting)
        // No early exit without permission: asking ScreenCaptureKit for the shareable content is
        // what makes macOS show its prompt and list Ledly under Screen Recording.
        // CGRequestScreenCaptureAccess alone doesn't register the app on recent macOS.
        if !CGPreflightScreenCaptureAccess(), !Self.didRequestAccess {
            Self.didRequestAccess = true
            DispatchQueue.main.async { CGRequestScreenCaptureAccess() }
        }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let wanted = config.displayID == 0 ? CGMainDisplayID() : config.displayID
                guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
                    onStatus?(.failed(tr("No se encuentra la pantalla.")))
                    return
                }
                let filter: SCContentFilter
                let size: CGSize
                if let bundleID = config.appBundleID, let window = Self.mainWindow(of: bundleID, in: content) {
                    // Only that window, wherever it is: the LEDs follow what it shows.
                    filter = SCContentFilter(desktopIndependentWindow: window)
                    size = window.frame.size
                    capturedWindow = (window.windowID, window.frame.size)
                    let app = window.owningApplication?.applicationName ?? bundleID
                    onSource?(window.title.map { $0.isEmpty ? tr("Ventana de %@", app) : tr("Ventana de %@: %@", app, $0) }
                              ?? tr("Ventana de %@", app))
                } else {
                    filter = SCContentFilter(display: display, excludingWindows: [])
                    size = CGSize(width: display.width, height: display.height)
                    capturedWindow = nil
                    let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }?.localizedName ?? tr("Pantalla")
                    if let bundleID = config.appBundleID {
                        let app = content.applications.first { $0.bundleIdentifier == bundleID }?.applicationName ?? bundleID
                        onSource?(tr("%@ no tiene ventanas visibles: capturando %@", app, name))
                    } else {
                        onSource?(name)
                    }
                }
                let sc = SCStreamConfiguration()
                let aspect = Double(size.height) / Double(max(size.width, 1))
                sc.width = Self.captureWidth
                sc.height = max(16, Int((Double(Self.captureWidth) * aspect).rounded()))
                sc.pixelFormat = kCVPixelFormatType_32BGRA
                sc.colorSpaceName = CGColorSpace.sRGB
                sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, min(config.fps, 60))))
                sc.queueDepth = 3
                sc.showsCursor = false
                sc.capturesAudio = false
                let stream = SCStream(filter: filter, configuration: sc, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                onStatus?(.running)
                watchApp(config)
            } catch {
                let nsError = error as NSError
                // -3801: the user declined screen recording.
                if nsError.code == -3801 {
                    onStatus?(.noPermission)
                } else {
                    onStatus?(.failed(error.localizedDescription))
                }
            }
        }
    }

    func stop() {
        appWatch?.cancel()
        appWatch = nil
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
        onStatus?(.stopped)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStatus?(.failed(error.localizedDescription))
        // Displays come and go (sleep, reconnect): try again shortly.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let config = self.config
            self.lock.unlock()
            if let config, self.stream == nil { self.restart(config) }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lock.lock()
        let config = self.config
        lock.unlock()
        guard let config else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let frame = BGRAFrame(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidth(pixels),
                              height: CVPixelBufferGetHeight(pixels),
                              rowBytes: CVPixelBufferGetBytesPerRow(pixels))
        let colors = analysis.colors(frame: frame, config: config)
        onColors?(colors)

        if previewWanted, Date().timeIntervalSince(lastPreview) > 0.15, let image = Self.image(of: frame) {
            lastPreview = Date()
            onPreview?(image, analysis.content)
        }
    }

    /// Copies the frame into a CGImage (the pixel buffer is reused by ScreenCaptureKit).
    private static func image(of f: BGRAFrame) -> CGImage? {
        let data = Data(bytes: f.base, count: f.rowBytes * f.height)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct BGRAFrame {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let rowBytes: Int

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> UnsafePointer<UInt8> {
        base + y * rowBytes + x * 4
    }
}

/// Turns frames into zone colors; keeps the black border detector's state between frames.
struct FrameAnalyzer {
    private static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func toSRGB(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private var border = BlackBorderDetector()
    /// Area of the last frame used for the zones, after cropping black borders (pixels).
    private(set) var content = CGRect.zero

    mutating func colors(frame: BGRAFrame, config: GrabberConfig) -> [RGB] {
        var content = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        if config.blackBorders {
            let (h, v) = border.process(frame)
            content = content.insetBy(dx: CGFloat(v), dy: CGFloat(h))
        } else {
            border.reset()
        }
        self.content = content
        return config.zones.map { zone in
            let x0 = Int((content.minX + zone.minX * content.width).rounded(.down))
            let x1 = max(x0 + 1, Int((content.minX + zone.maxX * content.width).rounded(.up)))
            let y0 = Int((content.minY + zone.minY * content.height).rounded(.down))
            let y1 = max(y0 + 1, Int((content.minY + zone.maxY * content.height).rounded(.up)))
            return average(frame, x0: max(0, x0), x1: min(frame.width, x1),
                           y0: max(0, y0), y1: min(frame.height, y1), mode: config.sampling)
        }
    }

    private func average(_ f: BGRAFrame, x0: Int, x1: Int, y0: Int, y1: Int, mode: SamplingMode) -> RGB {
        guard x1 > x0, y1 > y0 else { return .black }
        let count = Float((x1 - x0) * (y1 - y0))
        switch mode {
        case .mean:
            var r = 0, g = 0, b = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = f.pixel(x, y)
                    b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                }
            }
            return RGB(r: Float(r) / count / 255, g: Float(g) / count / 255, b: Float(b) / count / 255)

        case .linear:
            let lut = Self.toLinear
            var r: Float = 0, g: Float = 0, b: Float = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = f.pixel(x, y)
                    b += lut[Int(p[0])]; g += lut[Int(p[1])]; r += lut[Int(p[2])]
                }
            }
            return RGB(r: Self.toSRGB(r / count), g: Self.toSRGB(g / count), b: Self.toSRGB(b / count))

        case .dominant:
            // Average of the pixels that stand out most (bright and saturated).
            var best: Float = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = f.pixel(x, y)
                    best = max(best, Self.score(p))
                }
            }
            let cut = best * 0.7
            var r = 0, g = 0, b = 0, n = 0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = f.pixel(x, y)
                    guard Self.score(p) >= cut else { continue }
                    b += Int(p[0]); g += Int(p[1]); r += Int(p[2]); n += 1
                }
            }
            guard n > 0 else { return .black }
            let k = Float(n) * 255
            return RGB(r: Float(r) / k, g: Float(g) / k, b: Float(b) / k)
        }
    }

    @inline(__always) private static func score(_ p: UnsafePointer<UInt8>) -> Float {
        let hi = max(p[0], p[1], p[2]), lo = min(p[0], p[1], p[2])
        return Float(hi) * (0.4 + Float(hi - lo) / 255)
    }
}

/// Finds letterbox/pillarbox bars and only trusts a new size once it has been stable for a while.
struct BlackBorderDetector {
    /// Channel value at or below which a pixel counts as black (5 %).
    private static let threshold: UInt8 = 13
    /// Frames a new border must hold before it is used.
    private static let confirmFrames = 50

    private var current = (h: 0, v: 0)
    private var candidate = (h: 0, v: 0)
    private var stableFor = 0

    mutating func reset() {
        current = (0, 0)
        candidate = (0, 0)
        stableFor = 0
    }

    /// Returns the (horizontal bars height, vertical bars width) to crop, in pixels.
    mutating func process(_ f: BGRAFrame) -> (Int, Int) {
        guard let found = detect(f) else { return current }
        if abs(found.h - candidate.h) <= 1 && abs(found.v - candidate.v) <= 1 {
            stableFor += 1
        } else {
            candidate = found
            stableFor = 0
        }
        // Content growing into the bars is applied faster than new bars appearing.
        let needed = (candidate.h < current.h || candidate.v < current.v) ? 10 : Self.confirmFrames
        if stableFor >= needed {
            // One extra pixel so the soft edge of the picture doesn't bleed in.
            current = (candidate.h > 0 ? candidate.h + 1 : 0, candidate.v > 0 ? candidate.v + 1 : 0)
        }
        return current
    }

    private func isBlack(_ p: UnsafePointer<UInt8>) -> Bool {
        p[0] <= Self.threshold && p[1] <= Self.threshold && p[2] <= Self.threshold
    }

    /// nil when the frame is (almost) entirely black: nothing to learn from it.
    private func detect(_ f: BGRAFrame) -> (h: Int, v: Int)? {
        let xs = [f.width / 3, f.width / 2, f.width * 2 / 3]
        let ys = [f.height / 3, f.height / 2, f.height * 2 / 3]
        var top = 0
        while top < f.height / 2, xs.allSatisfy({ isBlack(f.pixel($0, top)) }) { top += 1 }
        guard top < f.height / 2 else { return nil }
        var bottom = 0
        while bottom < f.height / 2, xs.allSatisfy({ isBlack(f.pixel($0, f.height - 1 - bottom)) }) { bottom += 1 }
        var left = 0
        while left < f.width / 2, ys.allSatisfy({ isBlack(f.pixel(left, $0)) }) { left += 1 }
        guard left < f.width / 2 else { return nil }
        var right = 0
        while right < f.width / 2, ys.allSatisfy({ isBlack(f.pixel(f.width - 1 - right, $0)) }) { right += 1 }
        return (min(top, bottom), min(left, right))
    }
}
