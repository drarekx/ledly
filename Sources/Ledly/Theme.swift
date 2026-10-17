import SwiftUI

/// Ledly's dark look (same as Wallpy).
enum Theme {
    static let window = Color(hex: 0x121214)
    static let sidebar = Color(hex: 0x18181A)
    static let card = Color(hex: 0x1A1A1D)
    static let field = Color(hex: 0x202023)
    static let control = Color(hex: 0x26262A)
    static let line = Color(hex: 0x2A2A2E)
    static let lineStrong = Color(hex: 0x3A3A3F)

    static let text = Color(hex: 0xECECEE)
    static let text2 = Color(hex: 0xA1A1A6)
    static let text3 = Color(hex: 0x8A8A90)

    static let accent = Color(hex: 0x5C8CFF)
    static let accentText = Color(hex: 0x7AA2FF)
    static let accentFill = Color(hex: 0x3566E0)
    static let accentSoft = Color(hex: 0x22304F)
    static let accentBorder = Color(hex: 0x3D5BB0)
    static let navSelected = Color(hex: 0x26304A)

    static let ok = Color(hex: 0x3CCF7A)
    static let warn = Color(hex: 0xF5C46B)
    static let danger = Color(hex: 0xFF7B7B)
    static let dangerBorder = Color(hex: 0x4A2A2C)

    static let radius: CGFloat = 8
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - Buttons

struct LedlyButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, danger }
    var kind: Kind = .secondary
    var height: CGFloat = 32
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .regular))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(border, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return .white
            case .danger: return Theme.danger
            case .ghost: return Theme.text2
            case .secondary: return Theme.text
            }
        }

        private var background: Color {
            switch kind {
            case .primary: return Theme.accentFill
            case .secondary: return Theme.control
            case .ghost, .danger: return .clear
            }
        }

        private var border: Color {
            switch kind {
            case .primary: return .clear
            case .secondary: return Theme.lineStrong
            case .ghost: return Theme.line
            case .danger: return Theme.dangerBorder
            }
        }
    }
}

extension ButtonStyle where Self == LedlyButtonStyle {
    static var ledlyPrimary: LedlyButtonStyle { LedlyButtonStyle(kind: .primary) }
    static var ledlySecondary: LedlyButtonStyle { LedlyButtonStyle(kind: .secondary) }
    static var ledlyGhost: LedlyButtonStyle { LedlyButtonStyle(kind: .ghost) }
    static var ledlyDanger: LedlyButtonStyle { LedlyButtonStyle(kind: .danger) }
}

/// Square icon-only button.
struct IconButton: View {
    let symbol: String
    let label: String
    var kind: LedlyButtonStyle.Kind = .ghost
    var size: CGFloat = 32
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(LedlyButtonStyle(kind: kind, height: size))
        .frame(width: size)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Controls

/// Pill segmented control in the app's style.
struct SegmentedControl<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value
    var expand = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let (title, value) = options[index]
                let selected = value == selection
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.text2)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: expand ? .infinity : nil)
                        .frame(height: 26)
                        .background(selected ? Color(hex: 0x34343A) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.line) }
    }
}

/// Small uppercase heading used above groups.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.text3)
    }
}

/// Text field with the dark field look.
struct LedlyTextField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.lineStrong) }
    }
}

/// A labelled switch row.
struct SwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .tint(Theme.accentFill)
        .controlSize(.small)
        .padding(.vertical, 8)
    }
}

extension View {
    /// Rounded card surface.
    func ledlyCard(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
    }

    func monospacedText(size: CGFloat = 12) -> some View {
        self.font(.system(size: size, design: .monospaced))
    }
}

