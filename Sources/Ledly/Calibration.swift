import Foundation

/// Corners of the RGB cube, the colors the advanced calibration adjusts.
enum CalibrationCorner: String, CaseIterable, Identifiable, Codable {
    case red, green, blue, cyan, magenta, yellow, white, black
    var id: String { rawValue }

    /// The pure input color of this corner.
    var input: RGB {
        switch self {
        case .red: return RGB(r: 1, g: 0, b: 0)
        case .green: return RGB(r: 0, g: 1, b: 0)
        case .blue: return RGB(r: 0, g: 0, b: 1)
        case .cyan: return RGB(r: 0, g: 1, b: 1)
        case .magenta: return RGB(r: 1, g: 0, b: 1)
        case .yellow: return RGB(r: 1, g: 1, b: 0)
        case .white: return RGB(r: 1, g: 1, b: 1)
        case .black: return RGB(r: 0, g: 0, b: 0)
        }
    }

    var title: String {
        switch self {
        case .red: return tr("Rojo")
        case .green: return tr("Verde")
        case .blue: return tr("Azul")
        case .cyan: return tr("Cian")
        case .magenta: return tr("Magenta")
        case .yellow: return tr("Amarillo")
        case .white: return tr("Blanco")
        case .black: return tr("Negro")
        }
    }
}

/// Advanced calibration: the color the strip should show for each corner of the RGB cube.
/// Colors in between are interpolated trilinearly, so fixing a strip's green or its whites
/// fixes every mix of them too.
struct ColorCalibration: Codable, Equatable {
    var enabled = false
    var targets: [String: RGB] = [:]   // CalibrationCorner.rawValue → target; missing = untouched

    func target(_ corner: CalibrationCorner) -> RGB {
        targets[corner.rawValue] ?? corner.input
    }

    mutating func setTarget(_ color: RGB, for corner: CalibrationCorner) {
        targets[corner.rawValue] = color == corner.input ? nil : color
    }

    var isIdentity: Bool { targets.isEmpty }

    /// Precomputed corners in the order black, red, green, blue, cyan, magenta, yellow, white.
    func prepared() -> PreparedCalibration? {
        guard enabled, !isIdentity else { return nil }
        let order: [CalibrationCorner] = [.black, .red, .green, .blue, .cyan, .magenta, .yellow, .white]
        return PreparedCalibration(corners: order.map { target($0) })
    }
}

struct PreparedCalibration: Equatable {
    let corners: [RGB]

    /// Trilinear interpolation between the eight corners.
    func apply(_ c: RGB) -> RGB {
        let r = c.r, g = c.g, b = c.b
        let nr = 1 - r, ng = 1 - g, nb = 1 - b
        // Weight of each corner: how much of the input is "that" corner.
        let w: [Float] = [
            nr * ng * nb,   // black
            r * ng * nb,    // red
            nr * g * nb,    // green
            nr * ng * b,    // blue
            nr * g * b,     // cyan
            r * ng * b,     // magenta
            r * g * nb,     // yellow
            r * g * b,      // white
        ]
        var out = RGB.black
        for k in 0..<8 { out = out + corners[k] * w[k] }
        return out.clamped()
    }
}
