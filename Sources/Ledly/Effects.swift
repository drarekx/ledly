import CoreGraphics
import Foundation

/// Built-in animations. Raw values are stable: they are stored in settings and used by the API.
enum EffectKind: String, CaseIterable, Identifiable, Codable {
    case rainbowSwirl, doubleSwirl, rainbowWaves, rainbowMood, breath, candle, fire, knightRider, police, strobe,
         sparks, moodBlobs, seaWaves, plasma, snake, colorWipe, christmas, lightClock, aurora, meteor,
         musicPulse, musicSpectrum, musicWaves, musicMeter

    var id: String { rawValue }

    var title: String { tr(titleKey) }

    /// Spanish name, the translation key.
    var titleKey: String {
        switch self {
        case .rainbowSwirl: return "Remolino arcoíris"
        case .doubleSwirl: return "Doble remolino"
        case .rainbowWaves: return "Ondas arcoíris"
        case .rainbowMood: return "Arcoíris suave"
        case .breath: return "Respiración"
        case .candle: return "Vela"
        case .fire: return "Fuego"
        case .knightRider: return "Coche fantástico"
        case .police: return "Policía"
        case .strobe: return "Estroboscopio"
        case .sparks: return "Chispas"
        case .moodBlobs: return "Manchas de color"
        case .seaWaves: return "Olas del mar"
        case .plasma: return "Plasma"
        case .snake: return "Serpiente"
        case .colorWipe: return "Barrido"
        case .christmas: return "Navidad"
        case .lightClock: return "Reloj"
        case .aurora: return "Aurora"
        case .meteor: return "Meteoro"
        case .musicPulse: return "Pulso musical"
        case .musicSpectrum: return "Ecualizador"
        case .musicWaves: return "Ondas musicales"
        case .musicMeter: return "Vúmetro"
        }
    }

    var symbol: String {
        switch self {
        case .rainbowSwirl: return "rays"
        case .doubleSwirl: return "arrow.triangle.2.circlepath"
        case .rainbowWaves: return "wave.3.right"
        case .rainbowMood: return "rainbow"
        case .breath: return "wind"
        case .candle: return "flame"
        case .fire: return "flame.fill"
        case .knightRider: return "car.side"
        case .police: return "light.beacon.max"
        case .strobe: return "bolt"
        case .sparks: return "sparkle"
        case .moodBlobs: return "circle.hexagongrid"
        case .seaWaves: return "water.waves"
        case .plasma: return "aqi.medium"
        case .snake: return "point.topleft.down.to.point.bottomright.curvepath"
        case .colorWipe: return "paintbrush.pointed"
        case .christmas: return "tree"
        case .lightClock: return "clock"
        case .aurora: return "moon.stars"
        case .meteor: return "sparkles"
        case .musicPulse: return "music.note"
        case .musicSpectrum: return "chart.bar.fill"
        case .musicWaves: return "dot.radiowaves.left.and.right"
        case .musicMeter: return "gauge.with.needle"
        }
    }

    /// Effects that follow the system audio.
    var isMusic: Bool {
        switch self {
        case .musicPulse, .musicSpectrum, .musicWaves, .musicMeter: return true
        default: return false
        }
    }

    /// Effects that use the main color.
    var usesColor: Bool {
        switch self {
        case .breath, .knightRider, .strobe, .sparks, .snake, .colorWipe, .meteor: return true
        default: return false
        }
    }
}

/// A running effect. Stateful effects (fire, sparks…) keep their state between frames.
final class EffectRenderer {
    let kind: EffectKind
    private let zones: [LEDZone]
    /// Angle of each LED around the screen centre, 0…1, clockwise from the top.
    private let angles: [Float]
    private var heat: [Float]
    private var levels: [Float]
    private var phases: [Float]
    private var lastTime: Double?
    private var wipeHue: Float = 0
    private var rng = SystemRandomNumberGenerator()
    // Music effects
    private var smoothBands = [Float](repeating: 0, count: AudioLevels.bandCount)
    private var smoothBass: Float = 0
    private var smoothLevel: Float = 0
    private var peakHold: Float = 0
    private var seenBeat = Date.distantPast
    private var waves: [(born: Double, hue: Float)] = []

    init(kind: EffectKind, zones: [LEDZone]) {
        self.kind = kind
        self.zones = zones
        angles = zones.map { z in
            let a = atan2(Float(z.position.x - 0.5), Float(0.5 - z.position.y)) / (2 * .pi)
            return a < 0 ? a + 1 : a
        }
        heat = Array(repeating: 0, count: zones.count)
        levels = Array(repeating: 0, count: zones.count)
        phases = zones.map { _ in Float.random(in: 0...1) }
    }

    /// `time` in seconds, `speed` 0.1…3. `audio` feeds the music effects.
    func render(time: Double, speed: Double, color: RGB, audio: AudioLevels = .silent,
                equalizer: EqualizerOptions = EqualizerOptions()) -> [RGB] {
        let n = zones.count
        guard n > 0 else { return [] }
        let dt = Float(min(max(time - (lastTime ?? time), 0), 0.1))
        lastTime = time
        let t = Float(time * speed)
        var out = Array(repeating: RGB.black, count: n)
        if kind.isMusic { follow(audio, dt: dt) }

        switch kind {
        case .rainbowSwirl:
            for i in 0..<n { out[i] = RGB(hue: angles[i] + t * 0.15) }

        case .doubleSwirl:
            // Two rainbows turning in opposite directions, blended.
            for i in 0..<n {
                let a = RGB(hue: angles[i] * 2 + t * 0.12)
                let b = RGB(hue: -angles[i] * 2 + t * 0.07 + 0.5)
                out[i] = a.mix(b, (sin(angles[i] * 4 * .pi + t) + 1) / 2)
            }

        case .rainbowWaves:
            // The whole frame breathes outwards from the centre of the top edge.
            for i in 0..<n {
                let dx = Float(zones[i].position.x - 0.5), dy = Float(zones[i].position.y)
                out[i] = RGB(hue: sqrt(dx * dx + dy * dy) * 0.8 - t * 0.2)
            }

        case .rainbowMood:
            let c = RGB(hue: t * 0.03)
            for i in 0..<n { out[i] = c }

        case .breath:
            // Eased sine, never fully dark.
            let s = (sin(t * 1.3) + 1) / 2
            let level = 0.06 + 0.94 * s * s
            for i in 0..<n { out[i] = color * level }

        case .candle:
            let warm = RGB(r: 1, g: 0.42, b: 0.08)
            for i in 0..<n {
                // Each LED drifts towards a random target: soft flicker.
                if Float.random(in: 0...1, using: &rng) < dt * 8 * Float(speed) {
                    phases[i] = Float.random(in: 0.35...1, using: &rng)
                }
                levels[i] += (phases[i] - levels[i]) * min(1, dt * 12)
                out[i] = warm * levels[i]
            }

        case .fire:
            // 1-D heat simulation running from the bottom up both sides of the screen.
            let cooling = 0.9 * dt * Float(speed) * 6
            for i in 0..<n { heat[i] = max(0, heat[i] - Float.random(in: 0...cooling, using: &rng)) }
            let rows = fireRows()
            for row in rows {
                // Heat rises: every cell takes some of the cell below it.
                for k in stride(from: row.count - 1, through: 1, by: -1) {
                    let below = k >= 2 ? (heat[row[k - 1]] + heat[row[k - 2]] * 0.6) / 1.6 : heat[row[k - 1]]
                    heat[row[k]] += (below - heat[row[k]]) * min(1, dt * 18 * Float(speed))
                }
                if let base = row.first, Float.random(in: 0...1, using: &rng) < dt * 20 * Float(speed) {
                    heat[base] = min(1, heat[base] + Float.random(in: 0.5...1, using: &rng))
                }
            }
            for i in 0..<n { out[i] = Self.heatColor(heat[i]) }

        case .knightRider:
            // A bright eye bounces along the top edge (or the whole strip if there is no top).
            let path = indices(on: .top).isEmpty ? Array(0..<n) : indices(on: .top)
            let m = Float(path.count)
            let p = (1 - cos(t * 1.6)) / 2 * (m - 1)
            for (k, i) in path.enumerated() {
                let d = abs(Float(k) - p)
                out[i] = color * max(0, 1 - d / max(2, m * 0.08))
            }

        case .police:
            let red = RGB(r: 1, g: 0, b: 0), blue = RGB(r: 0, g: 0.1, b: 1)
            let phase = Int(t * 4) % 4
            for i in 0..<n {
                let leftHalf = zones[i].position.x < 0.5
                let on = phase == 0 || phase == 2
                if leftHalf { out[i] = on && phase == 0 ? red : (phase == 1 ? red * 0.15 : .black) }
                else { out[i] = on && phase == 2 ? blue : (phase == 3 ? blue * 0.15 : .black) }
            }

        case .strobe:
            let on = (t * 8).truncatingRemainder(dividingBy: 1) < 0.2
            for i in 0..<n { out[i] = on ? color : .black }

        case .sparks:
            for i in 0..<n {
                levels[i] = max(0, levels[i] - dt * 3)
                if Float.random(in: 0...1, using: &rng) < dt * 0.6 * Float(speed) { levels[i] = 1 }
                let l = levels[i]
                let glow: Float = l * l
                let spark: RGB = color.mix(RGB.white, glow)
                out[i] = spark * glow
            }

        case .moodBlobs:
            // Three hue blobs slowly orbit the screen.
            for i in 0..<n {
                var acc = RGB.black
                for b in 0..<3 {
                    let center = (Float(b) / 3 + t * 0.02 * Float(b + 1)).truncatingRemainder(dividingBy: 1)
                    var d = abs(angles[i] - center)
                    d = min(d, 1 - d)
                    let w = max(0, 1 - d * 4)
                    acc = acc + RGB(hue: t * 0.01 + Float(b) * 0.33) * (w * w)
                }
                out[i] = acc.clamped()
            }

        case .seaWaves:
            for i in 0..<n {
                let a = angles[i] * 2 * .pi
                let w = (sin(a * 3 + t * 1.2) + sin(a * 5 - t * 0.7) * 0.5 + 1.5) / 3
                out[i] = RGB(r: 0, g: 0.25 + 0.45 * w, b: 0.55 + 0.45 * w) * (0.3 + 0.7 * w)
            }

        case .plasma:
            for i in 0..<n {
                let x = Float(zones[i].position.x) * 6, y = Float(zones[i].position.y) * 6
                let v = sin(x + t) + sin(y * 1.3 - t * 0.8) + sin((x + y) * 0.7 + t * 0.6)
                out[i] = RGB(hue: v / 6 + t * 0.05)
            }

        case .snake:
            let length = max(4, n / 8)
            let head = Int(t * 30) % n
            for k in 0..<length {
                let i = ((head - k) % n + n) % n
                let l = 1 - Float(k) / Float(length)
                out[i] = color * (l * l)
            }

        case .colorWipe:
            // Fills the strip with one hue, then the next one wipes over it.
            let cycle = t * 0.25
            let progress = cycle - floor(cycle)
            let current = color.maxChannel > 0 && Int(cycle) % 2 == 0 ? color : RGB(hue: floor(cycle) * 0.23)
            let previous = Int(cycle) % 2 == 0 ? RGB(hue: (floor(cycle) - 1) * 0.23) : color
            let edge = Int(progress * Float(n))
            for i in 0..<n { out[i] = i <= edge ? current : previous }

        case .christmas:
            let red = RGB(r: 1, g: 0, b: 0), green = RGB(r: 0, g: 0.8, b: 0.1), white = RGB(r: 1, g: 0.85, b: 0.6)
            let shift = Int(t * 2)
            for i in 0..<n {
                let k = (i / 3 + shift) % 3
                out[i] = k == 0 ? red : (k == 1 ? green : white * 0.6)
            }

        case .lightClock:
            // Hour, minute and second hands drawn on the frame of the screen.
            let now = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
            let s = (Float(now.second ?? 0) + Float(now.nanosecond ?? 0) / 1e9) / 60
            let m = (Float(now.minute ?? 0) + s) / 60
            let h = (Float((now.hour ?? 0) % 12) + m) / 12
            for i in 0..<n {
                func hand(_ pos: Float, _ width: Float) -> Float {
                    var d = abs(angles[i] - pos)
                    d = min(d, 1 - d)
                    return max(0, 1 - d / width)
                }
                out[i] = (RGB(r: 1, g: 0.1, b: 0.05) * hand(h, 0.05)
                    + RGB(r: 0.1, g: 1, b: 0.2) * hand(m, 0.03)
                    + RGB(r: 0.15, g: 0.3, b: 1) * hand(s, 0.02)
                    + RGB(r: 0.03, g: 0.03, b: 0.03)).clamped()
            }

        case .aurora:
            for i in 0..<n {
                let a = angles[i] * 2 * .pi
                let v = (sin(a * 2 + t * 0.4) + sin(a * 3.7 - t * 0.25) + 2) / 4
                let hue = 0.33 + 0.25 * v + 0.05 * sin(t * 0.1)
                out[i] = RGB(hue: hue, saturation: 0.85, value: 0.15 + 0.85 * v * v)
            }

        case .meteor:
            for i in 0..<n {
                // Random decay leaves an uneven trail.
                if Float.random(in: 0...1, using: &rng) < 0.6 { levels[i] *= max(0, 1 - dt * 4) }
            }
            let head = Int(t * 40) % n
            for k in 0..<3 { levels[(head + k) % n] = 1 }
            for i in 0..<n { out[i] = color.mix(.white, levels[i] > 0.95 ? 0.6 : 0) * levels[i] }

        case .musicPulse:
            // The whole frame breathes with the bass; each beat nudges the hue.
            let hue = Float(time) * 0.02 * Float(speed) + wavesHueShift
            let l = 0.05 + 0.95 * smoothBass * smoothBass
            for i in 0..<n {
                out[i] = RGB(hue: hue + angles[i] * 0.15, saturation: 1, value: l)
            }

        case .musicSpectrum:
            if equalizerRenderer == nil { equalizerRenderer = EqualizerRenderer(zones: zones) }
            out = equalizerRenderer!.render(audio: audio, options: equalizer, time: time, dt: dt, speed: speed, color: color)

        case .musicWaves:
            // Every beat sends a ring of color from the bottom centre over the whole frame.
            let travel = 0.9 * Float(speed)
            waves.removeAll { Float(time - $0.born) * travel > 1.6 }
            for i in 0..<n {
                let d = distanceFromBottom(i)
                var acc = RGB.black
                for wave in waves {
                    let front = Float(time - wave.born) * travel
                    let k = max(0, 1 - abs(d - front) / 0.18) * max(0, 1 - front / 1.6)
                    acc = acc + RGB(hue: wave.hue) * k
                }
                out[i] = (acc + RGB(hue: wavesHueShift) * (0.04 + 0.1 * smoothLevel)).clamped()
            }

        case .musicMeter:
            // VU meter up both sides, green → yellow → red, with a falling peak dot.
            for i in 0..<n {
                let u = height(i)
                let base = RGB(hue: 0.33 - 0.33 * u)
                if u <= smoothLevel {
                    out[i] = base
                } else if abs(u - peakHold) < 0.04 {
                    out[i] = RGB.white * 0.7
                } else {
                    out[i] = base * 0.03
                }
            }
        }
        return out
    }

    private var wavesHueShift: Float = 0
    private var equalizerRenderer: EqualizerRenderer?

    /// Smooths the raw levels: rises at once, falls over ~150 ms (bands) or ~250 ms (bass, level).
    private func follow(_ audio: AudioLevels, dt: Float) {
        func approach(_ current: Float, _ target: Float, fall: Float) -> Float {
            target > current ? target : current + (target - current) * min(1, dt / fall)
        }
        for b in 0..<AudioLevels.bandCount {
            smoothBands[b] = approach(smoothBands[b], audio.bands[b], fall: 0.15)
        }
        smoothBass = approach(smoothBass, audio.bass, fall: 0.25)
        smoothLevel = approach(smoothLevel, audio.level, fall: 0.25)
        peakHold = smoothLevel > peakHold ? smoothLevel : max(0, peakHold - dt * 0.4)
        if audio.lastBeat > seenBeat {
            seenBeat = audio.lastBeat
            wavesHueShift += 0.13
            waves.append((born: lastTime ?? 0, hue: wavesHueShift))
            if waves.count > 8 { waves.removeFirst() }
        }
    }

    /// 0 at the bottom of the screen, 1 at the top; the top edge counts as the top.
    private func height(_ i: Int) -> Float {
        switch zones[i].side {
        case .top: return 1
        case .bottom: return 0
        case .left, .right: return Float(1 - zones[i].position.y)
        }
    }

    private func distanceFromBottom(_ i: Int) -> Float {
        let dx = Float(zones[i].position.x - 0.5), dy = Float(1 - zones[i].position.y)
        return sqrt(dx * dx + dy * dy)
    }

    private func indices(on side: ScreenSide) -> [Int] {
        zones.indices.filter { zones[$0].side == side }.sorted { zones[$0].position.x < zones[$1].position.x }
    }

    private var cachedRows: [[Int]]?

    /// Columns of LEDs for the fire: left and right edges, bottom to top, plus the top edge
    /// split from both ends towards the middle.
    private func fireRows() -> [[Int]] {
        if let cachedRows { return cachedRows }
        let left = zones.indices.filter { zones[$0].side == .left }.sorted { zones[$0].position.y > zones[$1].position.y }
        let right = zones.indices.filter { zones[$0].side == .right }.sorted { zones[$0].position.y > zones[$1].position.y }
        let top = indices(on: .top)
        let half = top.count / 2
        var rows = [left + Array(top[..<half]), right + Array(top[half...].reversed())]
        let bottom = zones.indices.filter { zones[$0].side == .bottom }
        rows += bottom.map { [$0] }
        rows = rows.filter { !$0.isEmpty }
        cachedRows = rows
        return rows
    }

    private static func heatColor(_ h: Float) -> RGB {
        let x = min(max(h, 0), 1)
        if x < 0.33 { return RGB(r: x * 3, g: 0, b: 0) }
        if x < 0.66 { return RGB(r: 1, g: (x - 0.33) * 3 * 0.6, b: 0) }
        return RGB(r: 1, g: 0.6 + (x - 0.66) * 1.2, b: (x - 0.66) * 1.5)
    }
}
