import CoreGraphics
import Foundation

/// Corner of the screen (seen from the front) where the first LED of the strip sits.
enum StartCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, topLeft, topRight, bottomRight
    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottomLeft: return tr("Abajo izquierda")
        case .topLeft: return tr("Arriba izquierda")
        case .topRight: return tr("Arriba derecha")
        case .bottomRight: return tr("Abajo derecha")
        }
    }
}

enum ScreenSide: String, Codable {
    case top, right, bottom, left
}

/// How the strip is glued around the back of the monitor.
struct LEDLayout: Codable, Equatable {
    var top = 20
    var right = 12
    var bottom = 20
    var left = 12
    var start: StartCorner = .bottomLeft
    /// Seen from the front of the screen.
    var clockwise = true
    /// Shifts every LED by this many positions (for strips that don't start exactly at a corner).
    var offset = 0
    /// LEDs missing in the middle of the bottom edge (monitor stand).
    var bottomGap = 0
    /// How far into the screen each LED samples, as a fraction of width/height.
    var depth: Double = 0.1
    /// Area overlap between neighbours (0 = none, 1 = double width).
    var overlap: Double = 0

    var count: Int { max(0, top + right + bottom + left - min(bottomGap, bottom)) }
}

/// One LED: where it sits around the screen and which part of the image it samples.
struct LEDZone: Equatable {
    /// Sampling rectangle in normalised screen coordinates (0…1, origin top-left).
    var rect: CGRect
    /// LED position on the frame of the screen (0…1, origin top-left), for previews and effects.
    var position: CGPoint
    var side: ScreenSide
}

extension LEDLayout {
    /// Zones in strip order (index 0 = first LED after the controller).
    func zones() -> [LEDZone] {
        // Build the ring clockwise from the top-left corner (as seen from the front).
        var ring: [LEDZone] = []
        let d = max(0.01, min(depth, 0.5))
        let ov = max(0, overlap)

        func span(_ i: Int, _ n: Int) -> (Double, Double) {
            let w = 1.0 / Double(n)
            let a = Double(i) * w - w * ov / 2
            return (max(0, a), min(1, a + w * (1 + ov)))
        }

        for i in 0..<max(top, 0) {
            let (a, b) = span(i, top)
            ring.append(LEDZone(rect: CGRect(x: a, y: 0, width: b - a, height: d),
                                position: CGPoint(x: (Double(i) + 0.5) / Double(top), y: 0), side: .top))
        }
        for i in 0..<max(right, 0) {
            let (a, b) = span(i, right)
            ring.append(LEDZone(rect: CGRect(x: 1 - d, y: a, width: d, height: b - a),
                                position: CGPoint(x: 1, y: (Double(i) + 0.5) / Double(right)), side: .right))
        }
        // Bottom runs right → left in clockwise order; the gap is centred.
        let gap = min(max(bottomGap, 0), bottom)
        let gapStart = (bottom - gap) / 2
        for k in 0..<max(bottom, 0) {
            let i = bottom - 1 - k
            if i >= gapStart && i < gapStart + gap { continue }
            let (a, b) = span(i, bottom)
            ring.append(LEDZone(rect: CGRect(x: a, y: 1 - d, width: b - a, height: d),
                                position: CGPoint(x: (Double(i) + 0.5) / Double(bottom), y: 1), side: .bottom))
        }
        for k in 0..<max(left, 0) {
            let i = left - 1 - k
            let (a, b) = span(i, left)
            ring.append(LEDZone(rect: CGRect(x: 0, y: a, width: d, height: b - a),
                                position: CGPoint(x: 0, y: (Double(i) + 0.5) / Double(left)), side: .left))
        }
        guard !ring.isEmpty else { return [] }

        let bottomCount = bottom - gap
        let cornerIndex: Int
        switch start {
        case .topLeft: cornerIndex = 0
        case .topRight: cornerIndex = top
        case .bottomRight: cornerIndex = top + right
        case .bottomLeft: cornerIndex = top + right + bottomCount
        }

        var ordered: [LEDZone]
        if clockwise {
            ordered = Array(ring[(cornerIndex % ring.count)...] + ring[..<(cornerIndex % ring.count)])
        } else {
            // Counter-clockwise from the same corner: the LED just before the corner comes first.
            let n = ring.count
            ordered = (0..<n).map { ring[((cornerIndex - 1 - $0) % n + n) % n] }
        }
        if offset != 0 {
            let n = ordered.count
            let s = ((offset % n) + n) % n
            ordered = Array(ordered[s...] + ordered[..<s])
        }
        return ordered
    }
}

// MARK: - Layout wizard

extension LEDLayout {
    /// Strip index of the LED sitting at each screen corner, taken as the first LED of the side
    /// that starts there going along the strip. This is what the layout wizard asks the user to mark.
    func cornerIndices() -> [StartCorner: Int] {
        let zones = zones()
        func first(_ side: ScreenSide, by key: (LEDZone) -> Double) -> Int? {
            zones.indices.filter { zones[$0].side == side }.min { key(zones[$0]) < key(zones[$1]) }
        }
        var result: [StartCorner: Int] = [:]
        if clockwise {
            result[.topLeft] = first(.top) { $0.position.x }
            result[.topRight] = first(.right) { $0.position.y }
            result[.bottomRight] = first(.bottom) { -$0.position.x }
            result[.bottomLeft] = first(.left) { -$0.position.y }
        } else {
            result[.topLeft] = first(.left) { $0.position.y }
            result[.bottomLeft] = first(.bottom) { $0.position.x }
            result[.bottomRight] = first(.right) { -$0.position.y }
            result[.topRight] = first(.top) { -$0.position.x }
        }
        return result
    }

    /// Works out the layout from what the user marked: the strip's LED count and the index of the
    /// LED at each corner. With `hasBottomGap`, the bottom gets as many missing LEDs as needed to
    /// match the density of the top edge. Depth and overlap are kept from `self`.
    /// Returns nil when the marks don't describe a strip going round the screen.
    func solved(count n: Int, corners marks: [StartCorner: Int], hasBottomGap: Bool) -> LEDLayout? {
        guard n >= 4, let tl = marks[.topLeft], let tr = marks[.topRight],
              let br = marks[.bottomRight], let bl = marks[.bottomLeft],
              Set([tl, tr, br, bl]).count == 4, [tl, tr, br, bl].allSatisfy({ (0..<n).contains($0) }) else { return nil }
        func d(_ a: Int, _ b: Int) -> Int { ((b - a) % n + n) % n }

        // Going clockwise from the top-left corner, the top-right one comes first.
        let clockwise = d(tl, tr) < d(tl, bl)
        var top, right, bottom, left: Int
        if clockwise {
            (top, right, bottom, left) = (d(tl, tr), d(tr, br), d(br, bl), d(bl, tl))
        } else {
            (left, bottom, right, top) = (d(tl, bl), d(bl, br), d(br, tr), d(tr, tl))
        }
        guard top + right + bottom + left == n, min(top, right, left) > 0 else { return nil }
        let gap = hasBottomGap ? max(0, top - bottom) : 0

        var best: LEDLayout?
        for start in StartCorner.allCases {
            for offset in stride(from: 0, through: n, by: 1).flatMap({ [$0, -$0] }) {
                if let best, abs(best.offset) <= abs(offset) { break }
                var candidate = self
                candidate.top = top
                candidate.right = right
                candidate.bottom = bottom + gap
                candidate.left = left
                candidate.bottomGap = gap
                candidate.start = start
                candidate.clockwise = clockwise
                candidate.offset = offset
                if candidate.count == n, candidate.cornerIndices() == marks {
                    best = candidate
                    break
                }
            }
        }
        return best
    }
}
