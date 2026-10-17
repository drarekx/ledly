import CoreGraphics
import Foundation

/// Where the equalizer's axis runs around the screen.
enum EqualizerLayout: String, CaseIterable, Identifiable, Codable {
    /// Bass at the bottom centre, treble at the top, up both sides.
    case fromBottom
    /// The same, upside down.
    case fromTop
    /// Like `fromBottom`, but the left half shows the left channel and the right half the right one.
    case stereo
    /// One axis round the whole frame, starting at the bottom centre.
    case ring
    /// Mirrored on both axes: from the middle of the top and bottom edges towards the sides.
    case quad
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fromBottom: return tr("Desde abajo")
        case .fromTop: return tr("Desde arriba")
        case .stereo: return tr("Estéreo")
        case .ring: return tr("Anillo")
        case .quad: return tr("Cuatro espejos")
        }
    }
}

/// How levels are drawn along the axis.
enum EqualizerStyle: String, CaseIterable, Identifiable, Codable {
    /// Each frequency glows as loud as it is.
    case spectrum
    /// The axis is split into bars that fill with their band.
    case bars
    /// The whole axis fills with the volume, with a falling peak dot.
    case level
    /// Only the loud moments of each band flash.
    case flashes
    var id: String { rawValue }

    var title: String {
        switch self {
        case .spectrum: return tr("Espectro")
        case .bars: return tr("Barras")
        case .level: return tr("Nivel")
        case .flashes: return tr("Destellos")
        }
    }
}

enum EqualizerColors: String, CaseIterable, Identifiable, Codable {
    /// Hue by frequency (position on the axis).
    case rainbow
    /// The main color.
    case fixed
    /// By intensity: dark blue → red → yellow → white.
    case heat
    /// Green → yellow → red along the axis.
    case traffic
    /// Rainbow that keeps turning.
    case cycle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .rainbow: return tr("Arcoíris")
        case .fixed: return tr("Color fijo")
        case .heat: return tr("Calor")
        case .traffic: return tr("Semáforo")
        case .cycle: return tr("Ciclo")
        }
    }
}

struct EqualizerOptions: Equatable, Codable {
    var layout: EqualizerLayout = .fromBottom
    var style: EqualizerStyle = .spectrum
    var colors: EqualizerColors = .rainbow
    /// Multiplies the levels: 0.5 = calmer, 2 = everything lights up.
    var sensitivity: Double = 1

    struct Preset: Identifiable {
        let id: String
        let title: String
        let options: EqualizerOptions
    }

    static var presets: [Preset] {
        [
            Preset(id: "classic", title: tr("Clásico"), options: .init(layout: .fromBottom, style: .bars, colors: .traffic)),
            Preset(id: "aurora", title: tr("Aurora"), options: .init(layout: .fromBottom, style: .spectrum, colors: .rainbow)),
            Preset(id: "stereo", title: tr("Estéreo"), options: .init(layout: .stereo, style: .level, colors: .traffic)),
            Preset(id: "fire", title: tr("Fuego"), options: .init(layout: .fromBottom, style: .spectrum, colors: .heat)),
            Preset(id: "rain", title: tr("Lluvia"), options: .init(layout: .fromTop, style: .bars, colors: .cycle)),
            Preset(id: "halo", title: tr("Halo"), options: .init(layout: .ring, style: .spectrum, colors: .cycle)),
            Preset(id: "club", title: tr("Club"), options: .init(layout: .quad, style: .flashes, colors: .rainbow)),
            Preset(id: "mono", title: tr("Monocolor"), options: .init(layout: .stereo, style: .bars, colors: .fixed)),
        ]
    }
}

/// Draws the configurable equalizer. Keeps its own smoothing so bars fall gently.
final class EqualizerRenderer {
    private let zones: [LEDZone]
    /// Position of each LED round the frame: 0 at the bottom centre, growing clockwise (seen from the front).
    private let perimeter: [Float]
    private var bands: [[Float]] = Array(repeating: Array(repeating: 0, count: AudioLevels.bandCount), count: 3)  // mono, left, right
    private var bandPeaks: [[Float]] = Array(repeating: Array(repeating: 0, count: AudioLevels.bandCount), count: 3)
    private var levels: [Float] = [0, 0, 0]
    private var levelPeaks: [Float] = [0, 0, 0]

    init(zones: [LEDZone]) {
        self.zones = zones
        // Walk the frame clockwise from the top-left corner, sides weighted 16:9.
        perimeter = zones.map { z in
            let x = Float(z.position.x), y = Float(z.position.y)
            let raw: Float
            switch z.side {
            case .top: raw = 16 * x
            case .right: raw = 16 + 9 * y
            case .bottom: raw = 25 + 16 * (1 - x)
            case .left: raw = 41 + 9 * (1 - y)
            }
            let t = (raw - 33) / 50   // bottom centre = 33
            return t - floor(t)
        }
    }

    func render(audio: AudioLevels, options: EqualizerOptions, time: Double, dt: Float, speed: Double, color: RGB) -> [RGB] {
        follow(audio, dt: dt, gain: Float(options.sensitivity))
        return zones.indices.map { i in
            let (p, channel) = axis(i, options.layout)
            return draw(p: p, channel: channel, options: options, time: time, speed: speed, color: color)
        }
    }

    /// Position on the axis (0 = start, bass) and channel (0 mono, 1 left, 2 right) of LED `i`.
    private func axis(_ i: Int, _ layout: EqualizerLayout) -> (Float, Int) {
        let t = perimeter[i]
        // 0 at the bottom centre, 1 at the top centre, the same on both halves.
        let fromBottom = t < 0.5 ? t * 2 : (1 - t) * 2
        switch layout {
        case .fromBottom: return (fromBottom, 0)
        case .fromTop: return (1 - fromBottom, 0)
        case .stereo: return (fromBottom, t < 0.5 ? 1 : 2)   // first half (left side seen from the front) = left
        case .ring: return (t, 0)
        case .quad:
            let q = t.truncatingRemainder(dividingBy: 0.5) * 2   // 0…1 per half
            return (q < 0.5 ? q * 2 : (1 - q) * 2, 0)
        }
    }

    private func draw(p: Float, channel: Int, options: EqualizerOptions, time: Double, speed: Double, color: RGB) -> RGB {
        let b = bands[channel]
        func band(at x: Float) -> Float {
            let f = min(max(x, 0), 1) * Float(AudioLevels.bandCount - 1)
            let lo = Int(f), hi = min(lo + 1, AudioLevels.bandCount - 1)
            return b[lo] + (b[hi] - b[lo]) * (f - Float(lo))
        }
        switch options.style {
        case .spectrum:
            let v = band(at: p)
            let base: RGB = paint(p: p, v: v, options, time, speed, color)
            let k: Float = v * v
            return base * k

        case .bars:
            // As many bars as fit with ~3 LEDs each would be ideal; 8 keeps them readable on short strips.
            let count: Float = 8
            let k = min(floor(p * count), count - 1)
            let inBar = p * count - k                  // 0…1 inside the bar
            let v = band(at: (k + 0.5) / count)
            let peak = bandPeaks[channel][Int(((k + 0.5) / count) * Float(AudioLevels.bandCount - 1))]
            if inBar <= v { return paint(p: (k + 0.5) / count, v: v, options, time, speed, color) }
            if abs(inBar - peak) < 0.12 { return RGB.white * 0.6 }
            return .black

        case .level:
            let v = levels[channel]
            if p <= v { return paint(p: p, v: p, options, time, speed, color) }
            if abs(p - levelPeaks[channel]) < 0.035 { return RGB.white * 0.7 }
            return paint(p: p, v: p, options, time, speed, color) * 0.03

        case .flashes:
            let v = band(at: p)
            let f = max(0, (v - 0.55) / 0.45)
            let k: Float = f * f
            let base: RGB = paint(p: p, v: v, options, time, speed, color).mix(RGB.white, k * 0.5)
            return base * k
        }
    }

    /// Color for axis position `p` and intensity `v`.
    private func paint(p: Float, v: Float, _ options: EqualizerOptions, _ time: Double, _ speed: Double, _ color: RGB) -> RGB {
        switch options.colors {
        case .rainbow: return RGB(hue: p * 0.8)
        case .fixed: return color
        case .heat:
            let x = min(max(v, 0), 1)
            if x < 0.25 { return RGB(r: 0.1 * x * 4, g: 0, b: 0.6 * x * 4) }
            if x < 0.6 { return RGB(r: 0.1 + 0.9 * (x - 0.25) / 0.35, g: 0, b: 0.6 * (1 - (x - 0.25) / 0.35)) }
            if x < 0.9 { return RGB(r: 1, g: 0.8 * (x - 0.6) / 0.3, b: 0) }
            return RGB(r: 1, g: 0.8 + 0.2 * (x - 0.9) / 0.1, b: (x - 0.9) / 0.1 * 0.7)
        case .traffic: return RGB(hue: 0.33 - 0.33 * min(max(p, 0), 1))
        case .cycle: return RGB(hue: p * 0.35 + Float(time * 0.06 * speed))
        }
    }

    /// Rises at once, falls over ~150 ms; peaks hold and drop slowly.
    private func follow(_ audio: AudioLevels, dt: Float, gain: Float) {
        let sources = [audio.bands, audio.leftBands, audio.rightBands]
        let sourceLevels = [audio.level, audio.leftLevel, audio.rightLevel]
        for c in 0..<3 {
            for k in 0..<AudioLevels.bandCount {
                let target = min(1, sources[c][k] * gain)
                bands[c][k] = target > bands[c][k] ? target : bands[c][k] + (target - bands[c][k]) * min(1, dt / 0.15)
                bandPeaks[c][k] = bands[c][k] > bandPeaks[c][k] ? bands[c][k] : max(0, bandPeaks[c][k] - dt * 0.5)
            }
            let target = min(1, sourceLevels[c] * gain)
            levels[c] = target > levels[c] ? target : levels[c] + (target - levels[c]) * min(1, dt / 0.25)
            levelPeaks[c] = levels[c] > levelPeaks[c] ? levels[c] : max(0, levelPeaks[c] - dt * 0.4)
        }
    }
}
