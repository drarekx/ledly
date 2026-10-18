import Foundation

/// Linear-ish RGB with channels in 0…1, the working format of the LED pipeline.
struct RGB: Equatable, Codable {
    var r: Float
    var g: Float
    var b: Float

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 1, g: 1, b: 1)

    init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(r8: Int, g8: Int, b8: Int) {
        self.init(r: Float(r8) / 255, g: Float(g8) / 255, b: Float(b8) / 255)
    }

    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(r8: Int(value >> 16 & 0xFF), g8: Int(value >> 8 & 0xFF), b8: Int(value & 0xFF))
    }

    /// Hue 0…1 (wraps), saturation and value 0…1.
    init(hue: Float, saturation: Float = 1, value: Float = 1) {
        let h = (hue - floor(hue)) * 6
        let i = Int(h) % 6
        let f = h - floor(h)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch i {
        case 0: self.init(r: value, g: t, b: p)
        case 1: self.init(r: q, g: value, b: p)
        case 2: self.init(r: p, g: value, b: t)
        case 3: self.init(r: p, g: q, b: value)
        case 4: self.init(r: t, g: p, b: value)
        default: self.init(r: value, g: p, b: q)
        }
    }

    var hex: String { String(format: "#%02X%02X%02X", r8, g8, b8) }
    var r8: Int { Self.byte(r) }
    var g8: Int { Self.byte(g) }
    var b8: Int { Self.byte(b) }
    var bytes: [Int] { [r8, g8, b8] }

    var maxChannel: Float { max(r, g, b) }
    var luminance: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static func byte(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    static func * (c: RGB, k: Float) -> RGB { RGB(r: c.r * k, g: c.g * k, b: c.b * k) }
    static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }

    func mix(_ other: RGB, _ t: Float) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    func clamped() -> RGB {
        RGB(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1))
    }
}

/// Color correction applied to every frame just before it goes to the strip.
struct ColorAdjustments: Equatable {
    /// 0…1, multiplies the output.
    var brightness: Float = 1
    /// Output = input ^ gamma. 1 = untouched; higher darkens mid tones (LEDs look washed out at 1).
    var gamma: Float = 1.5
    /// 0 = grey, 1 = untouched, 2 = double.
    var saturation: Float = 1
    /// White point in Kelvin; 6600 = neutral.
    var temperature: Float = 6600
    /// Minimum output (0…0.2) so the strip never goes fully dark in screen mode.
    var backlight: Float = 0
    /// Per-channel gain to balance cheap strips (they tend to be blue-ish).
    var redGain: Float = 1
    var greenGain: Float = 1
    var blueGain: Float = 1

    /// Advanced calibration (corners of the RGB cube); nil when off.
    var calibration: PreparedCalibration?

    /// Precomputed white-balance multipliers.
    private(set) var whiteBalance = RGB.white

    mutating func prepare() {
        whiteBalance = Self.kelvinToRGB(temperature)
    }

    func apply(_ input: RGB, useBacklight: Bool) -> RGB {
        var c = input.clamped()
        // Calibration first: it describes the strip, so the rest works on corrected colors.
        if let calibration { c = calibration.apply(c) }
        if saturation != 1 {
            let grey = c.luminance
            c = RGB(r: grey + (c.r - grey) * saturation,
                    g: grey + (c.g - grey) * saturation,
                    b: grey + (c.b - grey) * saturation).clamped()
        }
        if gamma != 1 {
            c = RGB(r: pow(c.r, gamma), g: pow(c.g, gamma), b: pow(c.b, gamma))
        }
        c = RGB(r: c.r * whiteBalance.r * redGain,
                g: c.g * whiteBalance.g * greenGain,
                b: c.b * whiteBalance.b * blueGain)
        if useBacklight && backlight > 0 {
            // Lift towards a dim version of the same hue, warm white if the input is black.
            let floor = backlight
            if c.maxChannel < floor {
                let tint = c.maxChannel > 0.001 ? c * (1 / c.maxChannel) : RGB(r: 1, g: 0.8, b: 0.6)
                c = tint * floor
            }
        }
        return (c * brightness).clamped()
    }

    /// Approximate white point of a black body (Tanner Helland's fit), normalised so the
    /// brightest channel is 1.
    static func kelvinToRGB(_ kelvin: Float) -> RGB {
        let t = min(max(kelvin, 1000), 40000) / 100
        var r: Float, g: Float, b: Float
        if t <= 66 {
            r = 255
            g = 99.4708025861 * log(t) - 161.1195681661
            b = t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307
        } else {
            r = 329.698727446 * pow(t - 60, -0.1332047592)
            g = 288.1221695283 * pow(t - 60, -0.0755148492)
            b = 255
        }
        let c = RGB(r: r / 255, g: g / 255, b: b / 255).clamped()
        let peak = max(c.maxChannel, 0.001)
        return c * (1 / peak)
    }
}
