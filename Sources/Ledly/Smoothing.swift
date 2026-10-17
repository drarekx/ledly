import Foundation

/// How colors move towards their target in screen mode.
enum SmoothingKind: String, CaseIterable, Identifiable {
    /// Each frame closes a fixed fraction of the gap: reacts at once, eases out.
    case exponential
    /// Critically damped spring (like HyperHDR's default "hybrid" interpolator): eases in and out,
    /// so sudden cuts look like a fade rather than a jump.
    case spring
    var id: String { rawValue }

    var title: String {
        switch self {
        case .exponential: return tr("Exponencial")
        case .spring: return tr("Muelle")
        }
    }
}

/// Smooths LED colors over time and turns them into the 8-bit values sent to the strip.
struct Smoother {
    private(set) var current: [RGB] = []
    private var velocity: [RGB] = []
    /// Last 8-bit values sent, per channel (r, g, b, r, g, b…).
    private var sent: [Int] = []

    /// Moves `current` towards `target`. `tau` is the time constant in seconds.
    mutating func step(towards target: [RGB], dt: Double, tau: Double, kind: SmoothingKind) {
        let n = target.count
        if current.count != n {
            current = target
            velocity = Array(repeating: .black, count: n)
            return
        }
        switch kind {
        case .exponential:
            let alpha = Float(1 - exp(-dt / tau))
            for i in 0..<n { current[i] = current[i].mix(target[i], alpha) }
        case .spring:
            // x'' = ω²(target − x) − 2ω x'. ω = 2/τ gives about the same settle time as the exponential.
            let omega = 2 / tau
            let steps = max(1, Int((dt * omega / 0.3).rounded(.up)))   // keep ω·h small for stability
            let h = Float(dt / Double(steps))
            let w = Float(omega)
            for _ in 0..<steps {
                for i in 0..<n {
                    let accel = (target[i] + current[i] * -1) * (w * w) + velocity[i] * (-2 * w)
                    velocity[i] = velocity[i] + accel * h
                    current[i] = current[i] + velocity[i] * h
                }
            }
        }
        // Snap when close enough, so fades really end (and the spring can't hover).
        for i in 0..<n {
            let c = current[i], t = target[i]
            if abs(c.r - t.r) < 0.0015 && abs(c.g - t.g) < 0.0015 && abs(c.b - t.b) < 0.0015 {
                current[i] = t
                velocity[i] = .black
            }
        }
    }

    /// Jumps straight to `colors` (mode changes, tests).
    mutating func reset(to colors: [RGB]) {
        current = colors
        velocity = Array(repeating: .black, count: colors.count)
    }

    /// 8-bit output. With `antiFlicker`, a channel only changes once the new value is at least
    /// a whole step away from the one already showing: values sitting right between two levels
    /// would otherwise toggle every frame, which is very visible on dim LEDs.
    /// `scale` dims the whole frame (power limit) without touching the smoothing state.
    mutating func quantized(antiFlicker: Bool, scale: Float = 1) -> [RGB] {
        let n = current.count
        if sent.count != n * 3 { sent = Array(repeating: -1, count: n * 3) }
        var out = [RGB]()
        out.reserveCapacity(n)
        for i in 0..<n {
            let c = (current[i] * scale).clamped()
            var bytes = [0, 0, 0]
            for (k, v) in [c.r, c.g, c.b].enumerated() {
                let exact = v * 255
                let previous = sent[i * 3 + k]
                if antiFlicker, previous >= 0, abs(exact - Float(previous)) < 1 {
                    bytes[k] = previous
                } else {
                    bytes[k] = Int(exact.rounded())
                }
                sent[i * 3 + k] = bytes[k]
            }
            out.append(RGB(r8: bytes[0], g8: bytes[1], b8: bytes[2]))
        }
        return out
    }
}

/// Rough WS2812B current draw, to keep the strip within what the supply (or USB) can give.
enum PowerModel {
    /// Per color channel at full brightness.
    static let milliampsPerChannel: Float = 20
    /// Each LED's controller, even when dark.
    static let idleMilliamps: Float = 1

    static func milliamps(_ colors: [RGB]) -> Float {
        colors.reduce(Float(colors.count) * idleMilliamps) { sum, c in
            let c = c.clamped()
            return sum + (c.r + c.g + c.b) * milliampsPerChannel
        }
    }

    /// Factor (≤ 1) that brings `colors` down to `limit` mA.
    static func scale(_ colors: [RGB], limit: Float) -> Float {
        let idle = Float(colors.count) * idleMilliamps
        let lit = milliamps(colors) - idle
        guard lit > 0, idle + lit > limit else { return 1 }
        return max(0, (limit - idle) / lit)
    }
}
