import Foundation
import ServiceManagement

/// What drives the strip while it is on.
enum LightMode: String, Codable, CaseIterable, Identifiable {
    case screen, effect, color
    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return tr("Pantalla")
        case .effect: return tr("Efecto")
        case .color: return tr("Color")
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "display"
        case .effect: return "sparkles"
        case .color: return "paintpalette"
        }
    }
}

/// How the color of each screen zone is computed.
enum SamplingMode: String, Codable, CaseIterable, Identifiable {
    /// Plain average.
    case mean
    /// Average in linear light (like HyperHDR's "advanced" mapping): bright details count
    /// as much as they look, so colors don't turn muddy.
    case linear
    /// Most saturated/brightest part of the zone wins.
    case dominant
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mean: return tr("Media")
        case .linear: return tr("Lineal")
        case .dominant: return tr("Dominante")
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    // Output
    @Published var isOn: Bool { didSet { defaults.set(isOn, forKey: "isOn") } }
    @Published var mode: LightMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var effect: EffectKind { didSet { defaults.set(effect.rawValue, forKey: "effect") } }
    /// 0.1…3, 1 = normal.
    @Published var effectSpeed: Double { didSet { defaults.set(effectSpeed, forKey: "effectSpeed") } }
    /// Layout, style and colors of the equalizer effect.
    @Published var equalizer: EqualizerOptions { didSet { save(equalizer, "equalizer") } }
    /// Main color for solid mode and for effects that use one.
    @Published var colorHex: String { didSet { defaults.set(colorHex, forKey: "colorHex") } }
    /// 0…1.
    @Published var brightness: Double { didSet { defaults.set(brightness, forKey: "brightness") } }

    // Device
    @Published var portPath: String? { didSet { defaults.set(portPath, forKey: "portPath") } }
    @Published var dataPin: Int { didSet { defaults.set(dataPin, forKey: "dataPin") } }
    @Published var layout: LEDLayout { didSet { save(layout, "layout") } }

    // Screen capture
    /// CGDirectDisplayID of the captured screen; 0 = main display.
    @Published var displayID: UInt32 { didSet { defaults.set(displayID, forKey: "displayID") } }
    @Published var captureFPS: Int { didSet { defaults.set(captureFPS, forKey: "captureFPS") } }
    @Published var sampling: SamplingMode { didSet { defaults.set(sampling.rawValue, forKey: "sampling") } }
    @Published var blackBorders: Bool { didSet { defaults.set(blackBorders, forKey: "blackBorders") } }

    // Image
    /// Smoothing time constant in milliseconds (screen mode).
    @Published var smoothingMs: Double { didSet { defaults.set(smoothingMs, forKey: "smoothingMs") } }
    @Published var smoothing: SmoothingKind { didSet { defaults.set(smoothing.rawValue, forKey: "smoothing") } }
    /// Hold 8-bit levels that would toggle every frame (dim scenes).
    @Published var antiFlicker: Bool { didSet { defaults.set(antiFlicker, forKey: "antiFlicker") } }
    @Published var gamma: Double { didSet { defaults.set(gamma, forKey: "gamma") } }
    @Published var saturation: Double { didSet { defaults.set(saturation, forKey: "saturation") } }
    @Published var temperature: Double { didSet { defaults.set(temperature, forKey: "temperature") } }
    @Published var backlight: Double { didSet { defaults.set(backlight, forKey: "backlight") } }
    @Published var redGain: Double { didSet { defaults.set(redGain, forKey: "redGain") } }
    @Published var greenGain: Double { didSet { defaults.set(greenGain, forKey: "greenGain") } }
    @Published var blueGain: Double { didSet { defaults.set(blueGain, forKey: "blueGain") } }
    /// Target color per corner of the RGB cube.
    @Published var calibration: ColorCalibration { didSet { save(calibration, "calibration") } }

    // API
    @Published var apiEnabled: Bool { didSet { defaults.set(apiEnabled, forKey: "apiEnabled") } }
    @Published var apiPort: Int { didSet { defaults.set(apiPort, forKey: "apiPort") } }
    /// Only accept connections from this Mac.
    @Published var apiLocalOnly: Bool { didSet { defaults.set(apiLocalOnly, forKey: "apiLocalOnly") } }
    /// Optional bearer token; empty = no auth.
    @Published var apiToken: String { didSet { defaults.set(apiToken, forKey: "apiToken") } }
    /// Receive LED frames over DDP (UDP).
    @Published var ddpEnabled: Bool { didSet { defaults.set(ddpEnabled, forKey: "ddpEnabled") } }
    @Published var ddpPort: Int { didSet { defaults.set(ddpPort, forKey: "ddpPort") } }
    /// Announce as a WLED device on the network (Home Assistant, WLED apps).
    @Published var wledDiscovery: Bool { didSet { defaults.set(wledDiscovery, forKey: "wledDiscovery") } }

    /// Dim the strip so its estimated draw stays under `powerLimitMilliamps`.
    @Published var powerLimitEnabled: Bool { didSet { defaults.set(powerLimitEnabled, forKey: "powerLimitEnabled") } }
    @Published var powerLimitMilliamps: Int { didSet { defaults.set(powerLimitMilliamps, forKey: "powerLimitMilliamps") } }

    /// Turn the strip off while the Mac sleeps or the screens are asleep.
    @Published var offWhenAsleep: Bool { didSet { defaults.set(offWhenAsleep, forKey: "offWhenAsleep") } }

    /// Stable fake MAC address for WLED clients that need a unique id.
    let deviceID: String

    private init() {
        defaults.register(defaults: [
            "isOn": true,
            "mode": LightMode.screen.rawValue,
            "effect": EffectKind.rainbowSwirl.rawValue,
            "effectSpeed": 1.0,
            "colorHex": "#FF8A3D",
            "brightness": 0.8,
            "dataPin": 6,
            "captureFPS": 30,
            "sampling": SamplingMode.linear.rawValue,
            "blackBorders": true,
            "smoothingMs": 150.0,
            "smoothing": SmoothingKind.spring.rawValue,
            "antiFlicker": true,
            "gamma": 1.5,
            "saturation": 1.0,
            "temperature": 6600.0,
            "backlight": 0.0,
            "redGain": 1.0,
            "greenGain": 1.0,
            "blueGain": 1.0,
            "apiEnabled": true,
            "apiPort": 8765,
            "apiLocalOnly": false,
            "apiToken": "",
            "wledDiscovery": true,
            "ddpEnabled": true,
            "ddpPort": 4048,
            "offWhenAsleep": true,
            "powerLimitEnabled": true,
            // Safe for a strip fed from a small supply; raise it to what the supply really gives.
            "powerLimitMilliamps": 1000,
        ])
        isOn = defaults.bool(forKey: "isOn")
        mode = LightMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .screen
        effect = EffectKind(rawValue: defaults.string(forKey: "effect") ?? "") ?? .rainbowSwirl
        effectSpeed = defaults.double(forKey: "effectSpeed")
        equalizer = defaults.data(forKey: "equalizer").flatMap { try? JSONDecoder().decode(EqualizerOptions.self, from: $0) } ?? EqualizerOptions()
        colorHex = defaults.string(forKey: "colorHex") ?? "#FF8A3D"
        brightness = defaults.double(forKey: "brightness")
        portPath = defaults.string(forKey: "portPath")
        dataPin = defaults.integer(forKey: "dataPin")
        layout = defaults.data(forKey: "layout").flatMap { try? JSONDecoder().decode(LEDLayout.self, from: $0) } ?? LEDLayout()
        displayID = UInt32(truncatingIfNeeded: defaults.integer(forKey: "displayID"))
        captureFPS = defaults.integer(forKey: "captureFPS")
        sampling = SamplingMode(rawValue: defaults.string(forKey: "sampling") ?? "") ?? .linear
        blackBorders = defaults.bool(forKey: "blackBorders")
        smoothingMs = defaults.double(forKey: "smoothingMs")
        smoothing = SmoothingKind(rawValue: defaults.string(forKey: "smoothing") ?? "") ?? .spring
        antiFlicker = defaults.bool(forKey: "antiFlicker")
        gamma = defaults.double(forKey: "gamma")
        saturation = defaults.double(forKey: "saturation")
        temperature = defaults.double(forKey: "temperature")
        backlight = defaults.double(forKey: "backlight")
        redGain = defaults.double(forKey: "redGain")
        greenGain = defaults.double(forKey: "greenGain")
        blueGain = defaults.double(forKey: "blueGain")
        calibration = defaults.data(forKey: "calibration").flatMap { try? JSONDecoder().decode(ColorCalibration.self, from: $0) } ?? ColorCalibration()
        apiEnabled = defaults.bool(forKey: "apiEnabled")
        apiPort = defaults.integer(forKey: "apiPort")
        apiLocalOnly = defaults.bool(forKey: "apiLocalOnly")
        apiToken = defaults.string(forKey: "apiToken") ?? ""
        wledDiscovery = defaults.bool(forKey: "wledDiscovery")
        ddpEnabled = defaults.bool(forKey: "ddpEnabled")
        ddpPort = defaults.integer(forKey: "ddpPort")
        offWhenAsleep = defaults.bool(forKey: "offWhenAsleep")
        powerLimitEnabled = defaults.bool(forKey: "powerLimitEnabled")
        powerLimitMilliamps = defaults.integer(forKey: "powerLimitMilliamps")
        if let id = defaults.string(forKey: "deviceID") {
            deviceID = id
        } else {
            deviceID = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            defaults.set(deviceID, forKey: "deviceID")
        }
    }

    var color: RGB {
        get { RGB(hex: colorHex) ?? RGB(r: 1, g: 0.54, b: 0.24) }
        set { colorHex = newValue.hex }
    }

    var adjustments: ColorAdjustments {
        var a = ColorAdjustments()
        a.brightness = Float(brightness)
        a.gamma = Float(gamma)
        a.saturation = Float(saturation)
        a.temperature = Float(temperature)
        a.backlight = Float(backlight)
        a.redGain = Float(redGain)
        a.greenGain = Float(greenGain)
        a.blueGain = Float(blueGain)
        a.calibration = calibration.prepared()
        a.prepare()
        return a
    }

    /// Back to the defaults for the image section only.
    func resetImage() {
        for key in ["smoothingMs", "smoothing", "antiFlicker", "gamma", "saturation", "temperature", "backlight", "redGain", "greenGain", "blueGain"] {
            defaults.removeObject(forKey: key)
        }
        smoothingMs = defaults.double(forKey: "smoothingMs")
        smoothing = SmoothingKind(rawValue: defaults.string(forKey: "smoothing") ?? "") ?? .spring
        antiFlicker = defaults.bool(forKey: "antiFlicker")
        gamma = defaults.double(forKey: "gamma")
        saturation = defaults.double(forKey: "saturation")
        temperature = defaults.double(forKey: "temperature")
        backlight = defaults.double(forKey: "backlight")
        redGain = defaults.double(forKey: "redGain")
        greenGain = defaults.double(forKey: "greenGain")
        blueGain = defaults.double(forKey: "blueGain")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Ledly: login item change failed: \(error)")
        }
    }
}
