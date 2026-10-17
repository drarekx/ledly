import AppKit
import ScreenCaptureKit
import SwiftUI

enum MainSection: Hashable {
    case home, effects, layout, device, image, api, settings
}

/// Main window: sidebar + the selected section, in Wallpy's dark style.
struct MainView: View {
    @State private var section: MainSection = .home
    @ObservedObject private var localizer = Localizer.shared

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch section {
                case .home: HomePane(openSection: { section = $0 })
                case .effects: EffectsPane()
                case .layout: LayoutPane()
                case .device: DevicePane()
                case .image: ImagePane()
                case .api: APIPane()
                case .settings: SettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(localizer.language)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .frame(minWidth: 960, minHeight: 620)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var section: MainSection
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.accentFill)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "lightspectrum.horizontal").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    }
                Text("Ledly").font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 8)

            VStack(spacing: 2) {
                navItem(tr("Inicio"), "house", .home)
                navItem(tr("Efectos"), "sparkles", .effects)
                navItem(tr("Disposición"), "rectangle.dashed", .layout)
                navItem(tr("Dispositivo"), "cpu", .device)
                navItem(tr("Imagen"), "camera.filters", .image)
                navItem(tr("API"), "network", .api)
                navItem(tr("Ajustes"), "slider.horizontal.3", .settings)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(deviceColor(engine.deviceStatus)).frame(width: 8, height: 8)
                    Text(deviceTitle(engine.deviceStatus)).fontWeight(.medium)
                }
                Text(statusDetail)
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    settings.isOn.toggle()
                } label: {
                    Label(settings.isOn ? tr("Apagar luces") : tr("Encender luces"),
                          systemImage: settings.isOn ? "power" : "lightbulb")
                }
                .buttonStyle(LedlyButtonStyle(kind: settings.isOn ? .secondary : .primary, height: 30, fullWidth: true))
            }
            .padding(12)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }

            Text(tr("Versión %@", Updater.currentVersion))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private var statusDetail: String {
        guard settings.isOn else { return tr("Luces apagadas") }
        if engine.liveSource != nil {
            return "\(tr("Tiempo real (DDP)")) · \(Int(engine.fps.rounded())) fps"
        }
        let what: String
        switch settings.mode {
        case .screen: what = tr("Siguiendo la pantalla")
        case .effect: what = settings.effect.title
        case .color: what = settings.colorHex
        }
        return "\(what) · \(tr("%d LEDs", settings.layout.count)) · \(Int(engine.fps.rounded())) fps"
    }

    private func navItem(_ title: String, _ symbol: String, _ value: MainSection) -> some View {
        let selected = section == value
        return Button { section = value } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                    .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                Text(title).fontWeight(selected ? .semibold : .regular)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func deviceColor(_ status: LEDDevice.Status) -> Color {
    switch status {
    case .connected: return Theme.ok
    case .connecting: return Theme.warn
    case .disconnected: return Theme.text3
    case .failed: return Theme.danger
    }
}

func deviceTitle(_ status: LEDDevice.Status) -> String {
    switch status {
    case .connected: return tr("Tira conectada")
    case .connecting: return tr("Conectando…")
    case .disconnected: return tr("Tira desconectada")
    case .failed: return tr("Error en la tira")
    }
}

// MARK: - Shared pieces

/// Pane scaffolding: title, subtitle and scrolling content.
struct Pane<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if let subtitle {
                        Text(subtitle).foregroundStyle(Theme.text2)
                    }
                }
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            .padding(.bottom, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Labelled slider with its value on the right.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundStyle(Theme.text)
                Spacer()
                Text(format(value)).monospacedText(size: 12).foregroundStyle(Theme.text2)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Integer stepper row.
struct StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)").monospacedText(size: 13).frame(minWidth: 32, alignment: .trailing)
            Stepper("", value: $value, in: range).labelsHidden()
        }
        .padding(.vertical, 3)
    }
}

/// Binding to the settings' main color for SwiftUI's ColorPicker.
var settingsColorBinding: Binding<Color> {
    Binding(
        get: {
            let c = Settings.shared.color
            return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b))
        },
        set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            Settings.shared.color = RGB(r: Float(ns.redComponent), g: Float(ns.greenComponent), b: Float(ns.blueComponent))
        })
}

extension RGB {
    var swiftUI: Color { Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b)) }
}

/// The screen with its LEDs around it, lit with the colors currently sent to the strip.
struct StripPreview: View {
    let zones: [LEDZone]
    let colors: [RGB]
    var showZones = false
    var showNumbers = false

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 18
            let screen = CGRect(x: inset, y: inset, width: geo.size.width - inset * 2, height: geo.size.height - inset * 2)
            ZStack {
                // Glow behind the screen.
                Canvas { ctx, _ in
                    for (i, zone) in zones.enumerated() {
                        let c = i < colors.count ? colors[i] : .black
                        let p = point(zone, screen, outset: 10)
                        let r: CGFloat = 26
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .radialGradient(Gradient(colors: [c.swiftUI.opacity(0.55), .clear]),
                                                       center: p, startRadius: 0, endRadius: r))
                    }
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(hex: 0x0B0B0D))
                    .frame(width: screen.width, height: screen.height)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.lineStrong) }
                    .position(x: screen.midX, y: screen.midY)
                Canvas { ctx, _ in
                    if showZones {
                        for zone in zones {
                            let r = CGRect(x: screen.minX + zone.rect.minX * screen.width,
                                           y: screen.minY + zone.rect.minY * screen.height,
                                           width: zone.rect.width * screen.width, height: zone.rect.height * screen.height)
                            ctx.stroke(Path(r), with: .color(Theme.accent.opacity(0.25)), lineWidth: 0.5)
                        }
                    }
                    for (i, zone) in zones.enumerated() {
                        let c = i < colors.count ? colors[i] : .black
                        let p = point(zone, screen, outset: 9)
                        let size: CGFloat = i == 0 && showNumbers ? 9 : 6
                        let dot = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
                        ctx.fill(Path(ellipseIn: dot), with: .color(c.maxChannel < 0.02 ? Color(hex: 0x2A2A2E) : c.swiftUI))
                        if showNumbers && (i == 0 || (i + 1) % 10 == 0 || i == zones.count - 1) {
                            let text = Text("\(i + 1)").font(.system(size: 9, weight: i == 0 ? .bold : .regular))
                                .foregroundColor(i == 0 ? Theme.ok : Theme.text3)
                            let q = point(zone, screen, outset: -8)
                            ctx.draw(text, at: q)
                        }
                    }
                }
            }
        }
    }

    private func point(_ zone: LEDZone, _ screen: CGRect, outset: CGFloat) -> CGPoint {
        var p = CGPoint(x: screen.minX + zone.position.x * screen.width, y: screen.minY + zone.position.y * screen.height)
        switch zone.side {
        case .top: p.y -= outset
        case .bottom: p.y += outset
        case .left: p.x -= outset
        case .right: p.x += outset
        }
        return p
    }
}

/// `StripPreview` fed with the colors going to the strip. Only this view redraws at frame rate.
struct LiveStripPreview: View {
    let layout: LEDLayout
    var showZones = false
    var showNumbers = false
    @ObservedObject private var preview = LEDEngine.shared.preview

    var body: some View {
        StripPreview(zones: layout.zones(), colors: preview.colors, showZones: showZones, showNumbers: showNumbers)
            .onAppear { preview.viewers += 1 }
            .onDisappear { preview.viewers -= 1 }
    }
}

// MARK: - Home

private struct HomePane: View {
    let openSection: (MainSection) -> Void
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared

    var body: some View {
        Pane(title: tr("Inicio"), subtitle: tr("La tira sigue los colores del borde de la pantalla, un efecto o un color fijo.")) {
            if let source = engine.liveSource {
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.accentText)
                    Text(tr("Tiempo real: la tira muestra los fotogramas que llegan de %@.", source))
                    Spacer()
                    Button(tr("Soltar")) { engine.endLive() }.buttonStyle(.ledlySecondary)
                }
                .padding(14)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accentBorder) }
            }
            if engine.grabberStatus == .noPermission {
                permissionBanner
            }
            if case .disconnected = engine.deviceStatus, engine.ports.isEmpty {
                banner(icon: "cable.connector", text: tr("No se ve ningún Arduino. Conéctalo por USB."), action: nil)
            }
            if case .failed(let message) = engine.deviceStatus {
                banner(icon: "exclamationmark.triangle", text: message, action: (tr("Ver dispositivo"), { openSection(.device) }))
            }

            LiveStripPreview(layout: settings.layout)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SegmentedControl(options: LightMode.allCases.map { ($0.title, $0) }, selection: Binding(
                        get: { settings.mode },
                        set: { settings.mode = $0; settings.isOn = true }))
                    Spacer()
                    Toggle(tr("Encendido"), isOn: $settings.isOn).toggleStyle(.switch).tint(Theme.accentFill)
                }
                SliderRow(title: tr("Brillo"), value: $settings.brightness, range: 0...1) { "\(Int(($0 * 100).rounded())) %" }
                switch settings.mode {
                case .color:
                    HStack {
                        Text(tr("Color"))
                        Spacer()
                        ColorPicker("", selection: settingsColorBinding, supportsOpacity: false).labelsHidden()
                        Text(settings.colorHex).monospacedText().foregroundStyle(Theme.text2)
                    }
                    presetColors
                case .effect:
                    HStack {
                        Image(systemName: settings.effect.symbol).foregroundStyle(Theme.accentText)
                        Text(settings.effect.title).fontWeight(.medium)
                        Spacer()
                        Button(tr("Elegir efecto…")) { openSection(.effects) }.buttonStyle(.ledlySecondary)
                    }
                case .screen:
                    HStack(spacing: 16) {
                        stat(tr("Captura"), captureText)
                        stat(tr("Suavizado"), "\(Int(settings.smoothingMs)) ms")
                        stat(tr("Bordes negros"), settings.blackBorders ? tr("Detectar") : tr("No"))
                        Spacer()
                        Button(tr("Ajustar imagen…")) { openSection(.image) }.buttonStyle(.ledlySecondary)
                    }
                }
            }
            .ledlyCard()

            HStack(spacing: 12) {
                infoCard(tr("LEDs"), "\(settings.layout.count)", "rectangle.dashed") { openSection(.layout) }
                infoCard(tr("Dispositivo"), deviceTitle(engine.deviceStatus), "cpu") { openSection(.device) }
                infoCard(tr("Refresco"), "\(Int(engine.fps.rounded())) fps", "speedometer") { openSection(.image) }
                infoCard(tr("API"), apiText, "network") { openSection(.api) }
            }
        }
    }

    private var presetColors: some View {
        let presets = ["#FFFFFF", "#FFB46B", "#FF8A3D", "#FF2D2D", "#FF2D95", "#9B5CFF", "#3D7BFF", "#2DD4FF", "#2DFF8A", "#E5FF2D"]
        return HStack(spacing: 8) {
            ForEach(presets, id: \.self) { hex in
                Button {
                    settings.colorHex = hex
                } label: {
                    Circle().fill((RGB(hex: hex) ?? .white).swiftUI).frame(width: 22, height: 22)
                        .overlay { Circle().strokeBorder(settings.colorHex == hex ? Color.white : Theme.lineStrong, lineWidth: settings.colorHex == hex ? 2 : 1) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var captureText: String {
        switch engine.grabberStatus {
        case .running: return tr("%d fps", settings.captureFPS)
        case .starting: return tr("Iniciando…")
        case .stopped: return tr("Parada")
        case .noPermission: return tr("Sin permiso")
        case .failed: return tr("Error")
        }
    }

    private var apiText: String {
        switch APIServer.shared.status {
        case .running(let port): return ":\(port)"
        case .stopped: return tr("Desactivada")
        case .failed: return tr("Error")
        }
    }

    private var permissionBanner: some View {
        banner(icon: "lock.shield", text: tr("Ledly necesita permiso de Grabación de pantalla para leer los colores. Actívalo y vuelve a abrir la app."),
               action: (tr("Abrir Ajustes"), {
                   CGRequestScreenCaptureAccess()
                   // Registers Ledly in the Screen Recording list (and shows the prompt).
                   Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
                   NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
               }))
    }

    private func banner(icon: String, text: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.warn)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action {
                Button(action.0, action: action.1).buttonStyle(.ledlySecondary)
            }
        }
        .padding(14)
        .background(Color(hex: 0x2A2416), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x4A3F22)) }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Text(value).fontWeight(.medium)
        }
    }

    private func infoCard(_ title: String, _ value: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(Theme.accentText)
                Text(value).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Effects

private struct EffectsPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Pane(title: tr("Efectos"), subtitle: tr("Animaciones que no dependen de la pantalla.")) {
            VStack(alignment: .leading, spacing: 12) {
                SliderRow(title: tr("Velocidad"), value: $settings.effectSpeed, range: 0.1...3) { String(format: "%.1f×", $0) }
                HStack {
                    Text(tr("Color del efecto"))
                    Spacer()
                    ColorPicker("", selection: settingsColorBinding, supportsOpacity: false).labelsHidden()
                }
                Text(tr("Solo lo usan los efectos marcados con ●."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .ledlyCard()

            if settings.mode == .effect && settings.effect == .musicSpectrum {
                EqualizerCard()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                ForEach(EffectKind.allCases) { effect in
                    EffectCard(effect: effect, selected: settings.mode == .effect && settings.effect == effect) {
                        settings.effect = effect
                        settings.mode = .effect
                        settings.isOn = true
                    }
                }
            }
        }
    }
}

/// Options of the equalizer effect: presets plus layout × style × colors.
private struct EqualizerCard: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "chart.bar.fill").foregroundStyle(Theme.accentText)
                Text(tr("Ecualizador")).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(tr("Combinaciones rápidas"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(EqualizerOptions.presets) { preset in
                        let active = preset.options.layout == settings.equalizer.layout
                            && preset.options.style == settings.equalizer.style
                            && preset.options.colors == settings.equalizer.colors
                        Button(preset.title) {
                            var options = preset.options
                            options.sensitivity = settings.equalizer.sensitivity
                            settings.equalizer = options
                        }
                        .buttonStyle(LedlyButtonStyle(kind: active ? .primary : .secondary, height: 28, fullWidth: true))
                    }
                }
            }
            row(tr("Disposición"), SegmentedControl(options: EqualizerLayout.allCases.map { ($0.title, $0) },
                                                    selection: $settings.equalizer.layout))
            row(tr("Estilo"), SegmentedControl(options: EqualizerStyle.allCases.map { ($0.title, $0) },
                                               selection: $settings.equalizer.style))
            row(tr("Colores"), SegmentedControl(options: EqualizerColors.allCases.map { ($0.title, $0) },
                                                selection: $settings.equalizer.colors))
            if settings.equalizer.colors == .fixed {
                HStack {
                    Text(tr("Color"))
                    Spacer()
                    ColorPicker("", selection: settingsColorBinding, supportsOpacity: false).labelsHidden()
                }
            }
            SliderRow(title: tr("Sensibilidad"), value: $settings.equalizer.sensitivity, range: 0.5...2.5) { String(format: "%.1f×", $0) }
            Text(tr("«Estéreo» pone el canal izquierdo en el lado izquierdo de la pantalla y el derecho en el derecho."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .ledlyCard()
    }

    private func row<Content: View>(_ title: String, _ content: Content) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            content
            Spacer()
        }
    }
}

private struct EffectCard: View {
    let effect: EffectKind
    let selected: Bool
    let action: () -> Void
    @State private var renderer: EffectRenderer?
    @State private var hovering = false

    /// A small ring of LEDs to preview the effect.
    private static let previewZones = LEDLayout(top: 12, right: 5, bottom: 12, left: 5, start: .bottomLeft).zones()

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                // Only the hovered and the active effect animate; the rest show a still frame.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !hovering && !selected)) { context in
                    let colors = (renderer ?? EffectRenderer(kind: effect, zones: Self.previewZones))
                        .render(time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000),
                                speed: Settings.shared.effectSpeed, color: Settings.shared.color,
                                audio: effect.isMusic ? .demo(time: context.date.timeIntervalSinceReferenceDate) : .silent,
                                equalizer: Settings.shared.equalizer)
                    StripPreview(zones: Self.previewZones, colors: colors)
                }
                .frame(height: 96)
                HStack(spacing: 8) {
                    Image(systemName: effect.symbol).foregroundStyle(selected ? Theme.accentText : Theme.text2)
                    Text(effect.title).fontWeight(.medium).lineLimit(1)
                    if effect.usesColor {
                        Circle().fill(Settings.shared.color.swiftUI).frame(width: 7, height: 7)
                    }
                    Spacer()
                }
            }
            .padding(12)
            .background(selected ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accentBorder : Theme.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { if renderer == nil { renderer = EffectRenderer(kind: effect, zones: Self.previewZones) } }
    }
}
