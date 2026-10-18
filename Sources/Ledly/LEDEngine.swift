import AppKit
import Combine
import Foundation

/// Everything the output loop needs, snapshotted from `Settings` on the main thread.
struct EngineConfig {
    var isOn = true
    var mode: LightMode = .screen
    var effect: EffectKind = .rainbowSwirl
    var effectSpeed: Double = 1
    var equalizer = EqualizerOptions()
    var color = RGB.white
    var adjustments = ColorAdjustments()
    var zones: [LEDZone] = []
    var smoothingMs: Double = 150
    var smoothing: SmoothingKind = .spring
    var antiFlicker = true
    /// mA the strip may draw; 0 = no limit.
    var powerLimit = 0
    var portPath: String?
    var displayID: CGDirectDisplayID = 0
    var captureFPS = 30
    var sampling: SamplingMode = .linear
    var blackBorders = true
}

/// A temporary look pushed through the API (`duration`), shown on top of the normal mode.
struct Overlay {
    var mode: LightMode
    var effect: EffectKind
    var color: RGB
    var until: Date
}

/// Lights used while setting up the strip.
enum TestPattern: Equatable {
    /// First LED green, second blue, last red: shows where the strip starts and which way it runs.
    case direction
    /// One color per side of the screen.
    case sides
    /// The whole strip shows this input color through the color correction (calibration).
    case calibration(RGB)
}

/// Drives the strip: picks the source, smooths, corrects colors and sends frames to the device.
@MainActor
final class LEDEngine: ObservableObject {
    static let shared = LEDEngine()

    enum FlashState: Equatable {
        case idle
        case running(Flasher.Step)
        case done
        case failed(String)
    }

    // Published for the UI and the API (main thread).
    /// Live colors, kept apart so only the previews redraw at frame rate.
    let preview = LEDPreview()
    @Published private(set) var deviceStatus: LEDDevice.Status = .disconnected
    @Published private(set) var grabberStatus: ScreenGrabber.Status = .stopped
    @Published private(set) var flashState: FlashState = .idle
    @Published private(set) var fps: Double = 0
    @Published private(set) var ports: [SerialPortInfo] = []
    @Published private(set) var overlayActive = false
    /// Frames from the network (DDP) are showing; nil when not. Holds the sender's address.
    @Published private(set) var liveSource: String?
    @Published var testPattern: TestPattern? { didSet { let t = testPattern; queue.async { self.loop.testPattern = t } } }

    private let queue = DispatchQueue(label: "ledly.engine", qos: .userInteractive)
    /// Owned by `queue`.
    private nonisolated(unsafe) let loop: OutputLoop
    private var cancellables = Set<AnyCancellable>()
    private var portTimer: Timer?
    private var sleeping = false

    private init() {
        loop = OutputLoop(queue: queue)
    }

    func start() {
        loop.publish = { [weak self] snapshot in
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
        loop.start()

        Settings.shared.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.pushConfig() }
            .store(in: &cancellables)
        pushConfig()

        refreshPorts()
        portTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPorts() }
        }

        let center = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.willSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.didWakeNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setSleeping(asleep) }
            }
        }
    }

    /// Turns the strip off and waits a moment so the last frame reaches it (app quitting).
    func shutdown() {
        queue.sync { loop.shutdown() }
    }

    private func setSleeping(_ value: Bool) {
        sleeping = value && Settings.shared.offWhenAsleep
        pushConfig()
    }

    func pushConfig() {
        let s = Settings.shared
        var c = EngineConfig()
        c.isOn = s.isOn && !sleeping
        c.mode = s.mode
        c.effect = s.effect
        c.effectSpeed = s.effectSpeed
        c.equalizer = s.equalizer
        c.color = s.color
        c.adjustments = s.adjustments
        c.zones = s.layout.zones()
        c.smoothingMs = s.smoothingMs
        c.smoothing = s.smoothing
        c.antiFlicker = s.antiFlicker
        c.powerLimit = s.powerLimitEnabled ? s.powerLimitMilliamps : 0
        c.portPath = s.portPath
        c.displayID = s.displayID
        c.captureFPS = s.captureFPS
        c.sampling = s.sampling
        c.blackBorders = s.blackBorders
        queue.async { self.loop.config = c }
    }

    func refreshPorts() {
        let list = SerialPortInfo.list()
        if list != ports { ports = list }
        // First run: pick the Arduino automatically.
        if Settings.shared.portPath == nil, let nano = list.first(where: \.looksLikeArduino) {
            Settings.shared.portPath = nano.path
        }
    }

    func reconnect() {
        queue.async { self.loop.forceReconnect() }
    }

    /// Shows a look for `duration` seconds, then returns to the normal mode.
    func showOverlay(mode: LightMode, effect: EffectKind?, color: RGB?, duration: TimeInterval) {
        let s = Settings.shared
        let overlay = Overlay(mode: mode, effect: effect ?? s.effect, color: color ?? s.color,
                              until: Date().addingTimeInterval(duration))
        overlayActive = true
        queue.async { self.loop.overlay = overlay }
    }

    /// A frame received over the network: R, G, B per LED from the start of the strip.
    nonisolated func receiveLive(_ bytes: [UInt8], from source: String) {
        queue.async { self.loop.receiveLive(bytes, from: source) }
    }

    /// Drops real-time mode at once (late packets are ignored for a moment).
    func endLive() {
        liveSource = nil
        queue.async { self.loop.endLive() }
    }

    func clearOverlay() {
        overlayActive = false
        queue.async { self.loop.overlay = nil }
    }

    /// Uploads the firmware for `pin` to the board on `path`.
    func installFirmware(pin: Int, path: String) {
        guard let url = Firmware.url(pin: pin), let hex = try? String(contentsOf: url, encoding: .utf8) else {
            flashState = .failed(tr("No se encuentra el firmware para el pin D%d.", pin))
            return
        }
        flashState = .running(.connecting)
        queue.async {
            self.loop.flashing = true
            self.loop.device.disconnect()
            self.loop.publishNow()
            let flasher = Flasher(path: path) { step in
                DispatchQueue.main.async { self.flashState = .running(step) }
            }
            let result: Result<Void, Error> = Result { try flasher.flash(hex: hex) }
            // Give the fresh sketch time to boot before connecting again.
            Thread.sleep(forTimeInterval: 0.5)
            self.loop.flashing = false
            self.loop.forceReconnect()
            DispatchQueue.main.async {
                switch result {
                case .success: self.flashState = .done
                case .failure(let error): self.flashState = .failed(error.localizedDescription)
                }
            }
        }
    }

    func resetFlashState() { flashState = .idle }

    /// Audio seen by the music effects; nil while none is showing.
    func audioLevels() -> AudioLevels? {
        queue.sync { loop.audioLevels() }
    }

    /// The frame last sent to the strip, read straight from the output loop.
    func currentColors() -> [RGB] {
        queue.sync { loop.output }
    }

    private func apply(_ snapshot: OutputLoop.Snapshot) {
        if preview.isWanted, preview.colors != snapshot.colors { preview.colors = snapshot.colors }
        if deviceStatus != snapshot.device { deviceStatus = snapshot.device }
        if grabberStatus != snapshot.grabber { grabberStatus = snapshot.grabber }
        if abs(fps - snapshot.fps) >= 0.5 { fps = snapshot.fps }
        if overlayActive != snapshot.overlay { overlayActive = snapshot.overlay }
        if liveSource != snapshot.liveSource { liveSource = snapshot.liveSource }
        if abs(preview.milliamps - snapshot.milliamps) >= 5 { preview.milliamps = snapshot.milliamps }
        if preview.powerLimited != snapshot.powerLimited { preview.powerLimited = snapshot.powerLimited }
    }
}

/// Values that change at frame rate, kept off `LEDEngine` so only the views that show them redraw.
/// `colors` is only updated while someone is looking.
@MainActor
final class LEDPreview: ObservableObject {
    @Published fileprivate(set) var colors: [RGB] = []
    /// Estimated current draw of the strip (mA); always kept up to date.
    @Published fileprivate(set) var milliamps: Double = 0
    /// The power limit is dimming the strip right now.
    @Published fileprivate(set) var powerLimited = false
    /// Preview views on screen.
    var viewers = 0
    /// WebSocket clients subscribed to the colors.
    var listeners = 0

    var isWanted: Bool { viewers > 0 || listeners > 0 }
}

/// The real-time part. Everything here runs on the engine queue.
final class OutputLoop {
    struct Snapshot {
        var colors: [RGB]
        var device: LEDDevice.Status
        var grabber: ScreenGrabber.Status
        var fps: Double
        var overlay: Bool
        var liveSource: String?
        var milliamps: Double
        var powerLimited: Bool
    }

    static let rate: Double = 50

    let device = LEDDevice()
    var publish: ((Snapshot) -> Void)?
    var config = EngineConfig() { didSet { configChanged(oldValue) } }
    var overlay: Overlay? { didSet { updateGrabber() } }
    /// Latest network frame; beats everything except the test patterns, "off" included.
    private var live: (colors: [RGB], source: String, at: Date)? {
        didSet { if (oldValue == nil) != (live == nil) { updateGrabber(); publishNow() } }
    }
    /// After `endLive`, packets still in flight are ignored until then.
    private var liveBlockedUntil = Date.distantPast
    /// No frame for this long ends real-time mode.
    static let liveTimeout: TimeInterval = 2.5
    var testPattern: TestPattern?
    var flashing = false

    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let grabber = ScreenGrabber()
    private let audio = AudioAnalyzer()
    private var grabberStatus: ScreenGrabber.Status = .stopped
    private var screenColors: [RGB] = []
    private var renderer: EffectRenderer?
    private var smoother = Smoother()
    private var milliamps: Float = 0
    private var powerLimited = false
    /// Last frame computed for the strip (8-bit values).
    private(set) var output: [RGB] = []
    private var lastSent: [RGB] = []
    private var lastSentAt = Date.distantPast
    private let startTime = Date()
    private var lastTick = Date()
    private var frameCount = 0
    private var sentCount = 0
    private var fpsWindowStart = Date()
    private var measuredFPS: Double = 0
    private var lastConnectAttempt = Date.distantPast
    /// Rainbow shown for a moment at launch, like HyperHDR's boot effect.
    private var bootUntil = Date().addingTimeInterval(2.5)
    private var bootRenderer: EffectRenderer?

    init(queue: DispatchQueue) {
        self.queue = queue
        grabber.onColors = { [weak self] colors in
            guard let self else { return }
            self.queue.async { self.screenColors = colors }
        }
        grabber.onStatus = { [weak self] status in
            guard let self else { return }
            self.queue.async { self.grabberStatus = status }
        }
    }

    func start() {
        queue.async {
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1 / Self.rate, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func shutdown() {
        grabber.update(nil)
        audio.stop()
        if device.isConnected {
            device.send(Array(repeating: .black, count: max(config.zones.count, 1)))
            Thread.sleep(forTimeInterval: 0.05)
        }
        device.disconnect()
    }

    func receiveLive(_ bytes: [UInt8], from source: String) {
        let now = Date()
        guard now >= liveBlockedUntil else { return }
        let n = config.zones.count
        var colors = Array(repeating: RGB.black, count: n)
        for i in 0..<min(n, bytes.count / 3) {
            colors[i] = RGB(r8: Int(bytes[i * 3]), g8: Int(bytes[i * 3 + 1]), b8: Int(bytes[i * 3 + 2]))
        }
        live = (colors, source, now)
    }

    func endLive() {
        live = nil
        liveBlockedUntil = Date().addingTimeInterval(1)
    }

    func audioLevels() -> AudioLevels? {
        audio.isRunning ? audio.current() : nil
    }

    func forceReconnect() {
        device.disconnect()
        lastConnectAttempt = .distantPast
    }

    func publishNow() {
        publish?(Snapshot(colors: output, device: device.status, grabber: grabberStatus,
                          fps: measuredFPS, overlay: overlay != nil, liveSource: live?.source,
                          milliamps: Double(milliamps), powerLimited: powerLimited))
    }

    private func configChanged(_ old: EngineConfig) {
        if config.portPath != old.portPath { forceReconnect() }
        if config.zones != old.zones || config.effect != old.effect {
            renderer = nil
            bootRenderer = nil
        }
        updateGrabber()
    }

    private var effectiveMode: LightMode { overlay?.mode ?? config.mode }

    private func updateGrabber() {
        // System audio only while a music effect is showing.
        // Nothing to capture while network frames are showing.
        let music = config.isOn && live == nil && effectiveMode == .effect && (overlay?.effect ?? config.effect).isMusic
        if music && !audio.isRunning { audio.start() }
        if !music && audio.isRunning { audio.stop() }

        let wanted = config.isOn && live == nil && effectiveMode == .screen && !config.zones.isEmpty
        grabber.update(wanted ? GrabberConfig(displayID: config.displayID, fps: config.captureFPS,
                                              zones: config.zones.map(\.rect), sampling: config.sampling,
                                              blackBorders: config.blackBorders) : nil)
    }

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 0.2)
        lastTick = now
        if flashing { return }

        if let overlay, overlay.until < now {
            self.overlay = nil
        }
        if let live, now.timeIntervalSince(live.at) > Self.liveTimeout {
            self.live = nil
        }
        maintainConnection(now)

        let n = config.zones.count
        let target = targetColors(now: now, count: n)
        // Screen mode uses the user's smoothing; everything else a short exponential fade.
        // Network frames are shown as they come: the sender does its own animation.
        let screen = effectiveMode == .screen && bootUntil < now && testPattern == nil && live == nil
        let tau = live != nil && testPattern == nil ? 0.001
            : screen ? max(config.smoothingMs, 1) / 1000 : 0.06
        smoother.step(towards: target, dt: dt, tau: tau, kind: screen ? config.smoothing : .exponential)
        let scale = config.powerLimit > 0 ? PowerModel.scale(smoother.current, limit: Float(config.powerLimit)) : 1
        output = smoother.quantized(antiFlicker: config.antiFlicker, scale: scale)
        milliamps = PowerModel.milliamps(output)
        powerLimited = scale < 0.999

        // A frame identical to the last one is only repeated twice a second (static color, paused
        // video, lights off): keeps the strip alive without busying the port and the Nano.
        if output == lastSent && now.timeIntervalSince(lastSentAt) < 0.5 {
            // skip
        } else if device.send(output) {
            sentCount += 1
            lastSent = output
            lastSentAt = now
        }

        frameCount += 1
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            measuredFPS = Double(sentCount) / now.timeIntervalSince(fpsWindowStart)
            sentCount = 0
            fpsWindowStart = now
        }
        if frameCount % 3 == 0 { publishNow() }
    }

    private func maintainConnection(_ now: Date) {
        guard let path = config.portPath else {
            if device.status != .disconnected { device.disconnect() }
            return
        }
        if device.isConnected { return }
        guard now.timeIntervalSince(lastConnectAttempt) > 3, FileManager.default.fileExists(atPath: path) else { return }
        lastConnectAttempt = now
        device.connect(path: path)
        lastTick = Date()
        publishNow()
    }

    private func targetColors(now: Date, count n: Int) -> [RGB] {
        guard n > 0 else { return [] }
        if let testPattern { return test(testPattern, count: n) }

        let raw: [RGB]
        if let live {
            // Network frames light the strip even when it is off; "off" comes back when they stop.
            raw = live.colors.count == n ? live.colors : Array(repeating: .black, count: n)
        } else if !config.isOn {
            return Array(repeating: .black, count: n)
        } else if bootUntil > now {
            if bootRenderer == nil { bootRenderer = EffectRenderer(kind: .rainbowSwirl, zones: config.zones) }
            raw = bootRenderer!.render(time: now.timeIntervalSince(startTime), speed: 3, color: config.color)
        } else {
            switch effectiveMode {
            case .screen:
                let current = smoother.current
                raw = screenColors.count == n ? screenColors : current.count == n ? current : Array(repeating: .black, count: n)
                if screenColors.count == n {
                    return raw.map { config.adjustments.apply($0, useBacklight: true) }
                }
                return raw
            case .effect:
                let kind = overlay?.effect ?? config.effect
                if renderer?.kind != kind { renderer = EffectRenderer(kind: kind, zones: config.zones) }
                raw = renderer!.render(time: now.timeIntervalSince(startTime), speed: config.effectSpeed,
                                       color: overlay?.color ?? config.color,
                                       audio: kind.isMusic ? audio.current() : .silent,
                                       equalizer: config.equalizer)
            case .color:
                raw = Array(repeating: overlay?.color ?? config.color, count: n)
            }
        }
        // Effects and solid colors are already "LED" colors: skip gamma and saturation.
        var a = config.adjustments
        a.gamma = 1
        a.saturation = 1
        return raw.map { a.apply($0, useBacklight: false) }
    }

    private func test(_ pattern: TestPattern, count n: Int) -> [RGB] {
        let dim: Float = 0.5
        switch pattern {
        case .direction:
            var out = Array(repeating: RGB(r: 0.04, g: 0.04, b: 0.04), count: n)
            out[0] = RGB(r: 0, g: 1, b: 0) * dim
            if n > 1 { out[1] = RGB(r: 0, g: 0, b: 1) * dim }
            if n > 2 { out[n - 1] = RGB(r: 1, g: 0, b: 0) * dim }
            return out
        case .sides:
            return config.zones.map { zone in
                switch zone.side {
                case .top: return RGB(r: 1, g: 0, b: 0) * dim
                case .right: return RGB(r: 0, g: 1, b: 0) * dim
                case .bottom: return RGB(r: 0, g: 0, b: 1) * dim
                case .left: return RGB(r: 1, g: 1, b: 0) * dim
                }
            }
        case .calibration(let color):
            // Same path as effects and solid colors: calibration, white balance, gains, brightness.
            var a = config.adjustments
            a.gamma = 1
            a.saturation = 1
            return Array(repeating: a.apply(color, useBacklight: false), count: n)
        }
    }
}
