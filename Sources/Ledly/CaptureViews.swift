import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Capture viewer

/// What the screen capture sees, with each LED's zone drawn on top in its current color and the
/// area left after cropping black borders.
struct CaptureViewer: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared
    @ObservedObject private var preview = LEDEngine.shared.preview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Vista de la captura"))
                Spacer()
                if !engine.captureSource.isEmpty && settings.mode == .screen {
                    Text(engine.captureSource).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            content
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let image = preview.captureImage, settings.mode == .screen {
                Text(borderText(image))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
        .ledlyCard()
        .onAppear {
            preview.captureViewers += 1
            preview.viewers += 1
        }
        .onDisappear {
            preview.captureViewers -= 1
            preview.viewers -= 1
        }
    }

    @ViewBuilder private var content: some View {
        if settings.mode != .screen || !settings.isOn {
            VStack(spacing: 10) {
                Text(tr("La captura solo funciona con la tira encendida en modo pantalla."))
                    .foregroundStyle(Theme.text2)
                Button(tr("Pasar a modo pantalla")) {
                    settings.mode = .screen
                    settings.isOn = true
                }
                .buttonStyle(.ledlySecondary)
            }
        } else if engine.grabberStatus == .noPermission {
            Text(tr("Falta el permiso de Grabación de pantalla.")).foregroundStyle(Theme.warn)
        } else if let image = preview.captureImage {
            GeometryReader { geo in
                let fit = fitted(CGSize(width: image.width, height: image.height), in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                    Canvas { ctx, _ in
                        let scale = fit.width / CGFloat(image.width)
                        let c = preview.captureContent
                        let area = CGRect(x: fit.minX + c.minX * scale, y: fit.minY + c.minY * scale,
                                          width: c.width * scale, height: c.height * scale)
                        let zones = settings.layout.zones()
                        for (i, zone) in zones.enumerated() {
                            let r = CGRect(x: area.minX + zone.rect.minX * area.width,
                                           y: area.minY + zone.rect.minY * area.height,
                                           width: zone.rect.width * area.width, height: zone.rect.height * area.height)
                            let color = i < preview.colors.count ? preview.colors[i].swiftUI : Theme.accent
                            ctx.fill(Path(r), with: .color(color.opacity(0.35)))
                            ctx.stroke(Path(r), with: .color(color), lineWidth: 1)
                        }
                        // The cropped area, when black borders are being ignored.
                        if area.width < fit.width - 1 || area.height < fit.height - 1 {
                            ctx.stroke(Path(area), with: .color(Theme.warn), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        }
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func fitted(_ size: CGSize, in box: CGSize) -> CGRect {
        let scale = min(box.width / max(size.width, 1), box.height / max(size.height, 1))
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    private func borderText(_ image: CGImage) -> String {
        let c = preview.captureContent
        let h = Int(c.minY.rounded()), v = Int(c.minX.rounded())
        if h == 0 && v == 0 {
            return tr("Captura de %d × %d px. Cada recuadro es la zona que lee un LED, pintada con su color.", image.width, image.height)
        }
        return tr("Bordes negros detectados: %d px arriba y abajo, %d px a los lados (de %d × %d). La línea discontinua marca la parte que se usa.",
                  h, v, image.width, image.height)
    }
}

// MARK: - Capture target

/// "Whole screen" or one app (Ledly follows its largest window).
struct CaptureTargetPicker: View {
    @ObservedObject private var settings = Settings.shared
    @State private var apps: [(id: String, name: String)] = []

    var body: some View {
        HStack {
            Text(tr("Capturar"))
            Spacer()
            Picker("", selection: Binding(
                get: { settings.captureApp ?? "" },
                set: { id in
                    settings.captureApp = id.isEmpty ? nil : id
                    settings.captureAppName = apps.first { $0.id == id }?.name ?? settings.captureAppName
                })) {
                Text(tr("Pantalla completa")).tag("")
                if let id = settings.captureApp, !apps.contains(where: { $0.id == id }) {
                    Text(tr("%@ (no abierta)", settings.captureAppName ?? id)).tag(id)
                }
                ForEach(apps, id: \.id) { app in
                    Text(app.name).tag(app.id)
                }
            }
            .labelsHidden()
            .frame(width: 260)
            IconButton(symbol: "arrow.clockwise", label: tr("Actualizar lista")) { Task { await load() } }
        }
        .task { await load() }
    }

    /// Apps with at least one normal window on screen.
    private func load() async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
        let own = Bundle.main.bundleIdentifier
        var seen: [String: String] = [:]
        for window in content.windows where window.isOnScreen && window.windowLayer == 0
            && window.frame.width >= 160 && window.frame.height >= 120 {
            guard let app = window.owningApplication, app.bundleIdentifier != own, !app.bundleIdentifier.isEmpty else { continue }
            seen[app.bundleIdentifier] = app.applicationName
        }
        apps = seen.map { ($0.key, $0.value) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Layout wizard

/// Finds the layout by lighting one LED at a time: the user moves it to the last LED and to each
/// corner, and Ledly works out LEDs per side, start corner, direction and offset.
struct LayoutWizard: View {
    let close: () -> Void
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared

    private enum Step: Equatable {
        case intro, last, corner(StartCorner), gap, result
    }

    private static let cornerOrder: [StartCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
    private static let maxLEDs = 400

    @State private var step: Step = .intro
    @State private var cursor = 0
    @State private var count = 0
    @State private var marks: [StartCorner: Int] = [:]
    @State private var hasGap = false
    @State private var result: LEDLayout?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.accentText)
                Text(tr("Asistente de disposición")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(tr("Cancelar"), action: finish).buttonStyle(.ledlyGhost)
            }
            Group {
                switch step {
                case .intro: intro
                case .last: cursorStep(title: tr("Último LED"),
                                       detail: tr("Mueve la luz blanca hasta el último LED de la tira (el más lejano del Arduino)."),
                                       corner: nil)
                case .corner(let corner): cursorStep(title: corner.title,
                                                     detail: tr("Mueve la luz hasta el LED que está justo en la esquina %@ de la pantalla (mirándola de frente).", corner.title.lowercased()),
                                                     corner: corner)
                case .gap: gapStep
                case .result: resultStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 620)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onDisappear { engine.testPattern = nil }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Vamos a encender un solo LED y moverlo por la tira. Mira la tira detrás del monitor y lleva la luz a cada punto que te pida: el último LED y las cuatro esquinas. Con eso Ledly calcula cuántos LEDs hay en cada lado, dónde empieza la tira y hacia dónde va."))
                .fixedSize(horizontal: false, vertical: true)
            Text(tr("Se mueve con los botones o con las flechas del teclado (← → de uno en uno, ↑ ↓ de diez en diez)."))
                .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Empezar")) {
                    cursor = max(0, settings.layout.count - 1)
                    step = .last
                    show()
                }
                .buttonStyle(.ledlyPrimary)
            }
        }
    }

    private func cursorStep(title: String, detail: String, corner: StartCorner?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                CornerDiagram(highlight: corner, marked: Set(marks.keys))
                    .frame(width: 150, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                stepButton("−10", -10)
                stepButton("−1", -1)
                Text(tr("LED %d", cursor + 1))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 120)
                stepButton("+1", 1)
                stepButton("+10", 10)
                Spacer()
            }
            HStack {
                if corner != nil {
                    Text(tr("De %d LEDs", count)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button(tr("Atrás"), action: back).buttonStyle(.ledlyGhost)
                Button(corner == nil ? tr("Este es el último") : tr("Esta es la esquina"), action: confirm)
                    .buttonStyle(.ledlyPrimary)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.downArrow) { move(-10); return .handled }
        .onKeyPress(.upArrow) { move(10); return .handled }
    }

    private var gapStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("¿Hay un hueco sin LEDs en el lado de abajo, por ejemplo para el pie del monitor?"))
            Text(tr("Si lo hay, Ledly deja ese hueco en el centro de abajo para que los LEDs de los lados lean el sitio correcto."))
                .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("Atrás"), action: back).buttonStyle(.ledlyGhost)
                Button(tr("No")) { hasGap = false; solve() }.buttonStyle(.ledlySecondary)
                Button(tr("Sí, hay hueco")) { hasGap = true; solve() }.buttonStyle(.ledlyPrimary)
            }
        }
    }

    @ViewBuilder private var resultStep: some View {
        if let result {
            VStack(alignment: .leading, spacing: 14) {
                StripPreview(zones: result.zones(), colors: [], showNumbers: true)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                Text(tr("Arriba %d · derecha %d · abajo %d · izquierda %d%@", result.top, result.right, result.bottom - result.bottomGap, result.left,
                        result.bottomGap > 0 ? tr(" · hueco de %d", result.bottomGap) : ""))
                    .fontWeight(.medium)
                Text(tr("Empieza en la esquina %@, en sentido %@, desplazamiento %d.", result.start.title.lowercased(),
                        result.clockwise ? tr("horario") : tr("antihorario"), result.offset))
                    .foregroundStyle(Theme.text2)
                HStack {
                    Spacer()
                    Button(tr("Volver a empezar")) { marks = [:]; step = .intro; engine.testPattern = nil }
                        .buttonStyle(.ledlyGhost)
                    Button(tr("Guardar")) {
                        settings.layout = result
                        engine.testPattern = .direction
                        finish()
                    }
                    .buttonStyle(.ledlyPrimary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Las esquinas marcadas no cuadran con una tira que dé la vuelta a la pantalla. Comprueba que marcaste cada esquina en su sitio y que la luz estaba en el último LED."))
                    .foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(tr("Volver a empezar")) { marks = [:]; step = .intro; engine.testPattern = nil }
                        .buttonStyle(.ledlyPrimary)
                }
            }
        }
    }

    private func stepButton(_ title: String, _ delta: Int) -> some View {
        Button(title) { move(delta) }
            .buttonStyle(LedlyButtonStyle(kind: .secondary, height: 34))
            .frame(width: 60)
    }

    private var limit: Int { step == .last ? Self.maxLEDs : max(count, 1) }

    private func move(_ delta: Int) {
        let n = limit
        cursor = ((cursor + delta) % n + n) % n
        show()
    }

    private func show() {
        engine.testPattern = .cursor(index: cursor, count: step == .last ? max(cursor + 11, settings.layout.count) : count)
    }

    private func confirm() {
        switch step {
        case .last:
            count = cursor + 1
            go(to: .corner(.topLeft))
        case .corner(let corner):
            marks[corner] = cursor
            if let i = Self.cornerOrder.firstIndex(of: corner), i + 1 < Self.cornerOrder.count {
                go(to: .corner(Self.cornerOrder[i + 1]))
            } else {
                step = .gap
                engine.testPattern = nil
            }
        default: break
        }
    }

    /// Next corner; starts the light where the current layout says that corner is, if it fits.
    private func go(to next: Step) {
        step = next
        if case .corner(let corner) = next {
            if let guess = marks[corner] ?? (settings.layout.count == count ? settings.layout.cornerIndices()[corner] : nil) {
                cursor = guess
            }
            cursor = min(cursor, count - 1)
            show()
        }
    }

    private func back() {
        switch step {
        case .last: step = .intro; engine.testPattern = nil
        case .corner(let corner):
            if let i = Self.cornerOrder.firstIndex(of: corner), i > 0 {
                go(to: .corner(Self.cornerOrder[i - 1]))
            } else {
                cursor = count - 1
                step = .last
                show()
            }
        case .gap: go(to: .corner(.bottomLeft))
        default: break
        }
    }

    private func solve() {
        result = settings.layout.solved(count: count, corners: marks, hasBottomGap: hasGap)
        step = .result
    }

    private func finish() {
        if case .cursor = engine.testPattern { engine.testPattern = nil }
        close()
    }
}

/// Small monitor drawing with the corner being asked for highlighted.
private struct CornerDiagram: View {
    let highlight: StartCorner?
    let marked: Set<StartCorner>

    var body: some View {
        GeometryReader { geo in
            let r = CGRect(origin: .zero, size: geo.size).insetBy(dx: 12, dy: 12)
            ZStack {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.lineStrong, lineWidth: 2)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                ForEach([StartCorner.topLeft, .topRight, .bottomRight, .bottomLeft]) { corner in
                    let p = point(corner, r)
                    Circle()
                        .fill(corner == highlight ? Color.white : marked.contains(corner) ? Theme.ok : Theme.line)
                        .frame(width: corner == highlight ? 14 : 9, height: corner == highlight ? 14 : 9)
                        .position(p)
                }
            }
        }
    }

    private func point(_ corner: StartCorner, _ r: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        }
    }
}

// MARK: - White balance wizard

/// Shows white (or grey) on the strip next to the same color on screen and lets the user fix the
/// channel gains and temperature until both look alike.
struct WhiteBalanceWizard: View {
    let close: () -> Void
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared
    @State private var level: Double = 1
    @State private var saved: (Double, Double, Double, Double)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.accentText)
                Text(tr("Balance de blancos")).font(.system(size: 17, weight: .semibold))
                Spacer()
            }
            Text(tr("La tira se pone en el mismo blanco que el recuadro de abajo. Mira los dos a la vez y mueve los controles hasta que el blanco de la tira se parezca al de la pantalla. Las tiras baratas suelen salir azuladas: baja un poco el azul o la temperatura."))
                .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: level))
                    .frame(width: 180, height: 120)
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.lineStrong) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Comparar con"))
                    SegmentedControl(options: [(tr("Blanco"), 1.0), (tr("Gris 50 %"), 0.5), (tr("Gris 20 %"), 0.2)],
                                     selection: $level)
                    Text(tr("El gris sirve para ver si a poco brillo cambia el tono.")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }
            SliderRow(title: tr("Temperatura"), value: $settings.temperature, range: 2500...10000, step: 100) { "\(Int($0)) K" }
            SliderRow(title: tr("Rojo"), value: $settings.redGain, range: 0...1)
            SliderRow(title: tr("Verde"), value: $settings.greenGain, range: 0...1)
            SliderRow(title: tr("Azul"), value: $settings.blueGain, range: 0...1)
            HStack {
                Button(tr("Deshacer cambios")) {
                    if let saved {
                        (settings.temperature, settings.redGain, settings.greenGain, settings.blueGain) = saved
                    }
                }
                .buttonStyle(.ledlyGhost)
                Spacer()
                Button(tr("Hecho")) { close() }.buttonStyle(.ledlyPrimary)
            }
        }
        .padding(24)
        .frame(width: 560)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onAppear {
            saved = (settings.temperature, settings.redGain, settings.greenGain, settings.blueGain)
            show()
        }
        .onChange(of: level) { _, _ in show() }
        .onDisappear {
            if case .calibration = engine.testPattern { engine.testPattern = nil }
        }
    }

    /// The screen swatch is sRGB; the strip gets the same value through the color correction.
    private func show() {
        let v = Float(level)
        engine.testPattern = .calibration(RGB(r: v, g: v, b: v))
    }
}
