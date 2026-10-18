import AppKit
import ScreenCaptureKit
import SwiftUI

// MARK: - Layout

struct LayoutPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared
    @State private var showWizard = false

    var body: some View {
        Pane(title: tr("Disposición"), subtitle: tr("Cuántos LEDs hay en cada lado y por dónde empieza la tira, mirando la pantalla de frente.")) {
            LiveStripPreview(layout: settings.layout, showZones: true, showNumbers: true)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(tr("LEDs por lado"))
                    StepperRow(title: tr("Arriba"), value: $settings.layout.top, range: 0...200)
                    StepperRow(title: tr("Derecha"), value: $settings.layout.right, range: 0...200)
                    StepperRow(title: tr("Abajo"), value: $settings.layout.bottom, range: 0...200)
                    StepperRow(title: tr("Izquierda"), value: $settings.layout.left, range: 0...200)
                    StepperRow(title: tr("Hueco abajo (pie)"), value: $settings.layout.bottomGap, range: 0...max(0, settings.layout.bottom))
                    Divider().overlay(Theme.line).padding(.vertical, 6)
                    HStack {
                        Text(tr("Total"))
                        Spacer()
                        Text(tr("%d LEDs", settings.layout.count)).fontWeight(.semibold)
                    }
                    if settings.layout.count > 400 {
                        Text(tr("El firmware del Nano admite hasta 400 LEDs."))
                            .font(.system(size: 11)).foregroundStyle(Theme.danger)
                    }
                }
                .ledlyCard()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(tr("Inicio y sentido"))
                    Picker(tr("Primer LED"), selection: $settings.layout.start) {
                        ForEach(StartCorner.allCases) { Text($0.title).tag($0) }
                    }
                    SegmentedControl(options: [(tr("Horario"), true), (tr("Antihorario"), false)],
                                     selection: $settings.layout.clockwise, expand: true)
                    StepperRow(title: tr("Desplazamiento"), value: $settings.layout.offset, range: -200...200)
                    SliderRow(title: tr("Profundidad de muestreo"), value: $settings.layout.depth, range: 0.03...0.3) { "\(Int(($0 * 100).rounded())) %" }
                    SliderRow(title: tr("Solapamiento"), value: $settings.layout.overlap, range: 0...1) { "\(Int(($0 * 100).rounded())) %" }
                }
                .ledlyCard()
            }

            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars").font(.system(size: 20)).foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Asistente de disposición")).fontWeight(.semibold)
                    Text(tr("Enciende un LED, llévalo al último y a cada esquina, y Ledly calcula el resto."))
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                Button(tr("Empezar…")) { showWizard = true }.buttonStyle(.ledlyPrimary)
                    .disabled(!engine.deviceStatus.isConnectedStatus)
            }
            .ledlyCard()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(tr("Comprobar"))
                Text(tr("«Dirección» enciende el primer LED en verde, el segundo en azul y el último en rojo. «Lados» pinta cada lado de un color: arriba rojo, derecha verde, abajo azul, izquierda amarillo."))
                    .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack {
                    testButton(tr("Dirección"), .direction)
                    testButton(tr("Lados"), .sides)
                    if engine.testPattern != nil {
                        Button(tr("Terminar prueba")) { engine.testPattern = nil }.buttonStyle(.ledlyPrimary)
                    }
                }
            }
            .ledlyCard()
        }
        .onDisappear { engine.testPattern = nil }
        .sheet(isPresented: $showWizard) {
            LayoutWizard { showWizard = false }
        }
    }

    private func testButton(_ title: String, _ pattern: TestPattern) -> some View {
        Button(title) { engine.testPattern = pattern }
            .buttonStyle(SelectableButtonStyle(selected: engine.testPattern == pattern))
    }
}

/// Secondary button that shows a selected state.
struct SelectableButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        LedlyButtonStyle(kind: selected ? .primary : .secondary).makeBody(configuration: configuration)
    }
}

// MARK: - Device

struct DevicePane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared

    var body: some View {
        Pane(title: tr("Dispositivo"), subtitle: tr("Arduino Nano con tira WS2812B, conectado por USB.")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Circle().fill(deviceColor(engine.deviceStatus)).frame(width: 10, height: 10)
                    Text(deviceTitle(engine.deviceStatus)).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button(tr("Reconectar")) { engine.reconnect() }.buttonStyle(.ledlySecondary)
                        .disabled(settings.portPath == nil)
                }
                if case .connected(let firmware) = engine.deviceStatus {
                    Text(firmware.map { tr("Firmware: %@", $0) } ?? tr("Firmware Adalight sin identificar (no es el de Ledly)."))
                        .foregroundStyle(Theme.text2)
                    if let version = LEDDevice.ledlyVersion(firmware), version < Firmware.version {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.circle.fill").foregroundStyle(Theme.warn)
                            Text(tr("El Nano lleva la versión %d del firmware; la app trae la %d, que va más rápida.", version, Firmware.version))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button(tr("Actualizar firmware")) {
                                if let pin = LEDDevice.ledlyPin(firmware) { settings.dataPin = pin }
                                if let path = settings.portPath { engine.installFirmware(pin: settings.dataPin, path: path) }
                            }
                            .buttonStyle(.ledlyPrimary)
                        }
                    }
                }
                if case .failed(let message) = engine.deviceStatus {
                    Text(message).foregroundStyle(Theme.danger)
                }

                SectionLabel(tr("Puerto")).padding(.top, 6)
                if engine.ports.isEmpty {
                    Text(tr("No hay ningún puerto USB serie. Conecta el Arduino.")).foregroundStyle(Theme.text3)
                }
                ForEach(engine.ports) { port in
                    portRow(port)
                }
                if let path = settings.portPath, !engine.ports.contains(where: { $0.path == path }) {
                    portRow(SerialPortInfo(path: path, name: tr("No conectado"), vendorID: nil, productID: nil))
                }
            }
            .ledlyCard()

            FirmwareCard()

            PowerCard()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(tr("Conexión"))
                Text(tr("Datos de la tira (DIN) al pin elegido del Nano, con una resistencia de 330 Ω si puedes. GND de la tira al GND del Nano. Alimenta la tira con una fuente de 5 V propia: el USB solo aguanta unos pocos LEDs a poco brillo."))
                    .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                Text(tr("Protocolo Adalight a %d baudios. El firmware de Ledly confirma cada fotograma, así que no se pierden datos.", Firmware.baud))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .ledlyCard()
        }
    }

    private func portRow(_ port: SerialPortInfo) -> some View {
        let selected = settings.portPath == port.path
        return Button {
            settings.portPath = port.path
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accentText : Theme.text3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(port.name).fontWeight(.medium)
                        if port.looksLikeArduino {
                            Text(tr("Arduino")).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Theme.accentSoft, in: Capsule())
                                .foregroundStyle(Theme.accentText)
                        }
                    }
                    Text(port.detail).monospacedText(size: 11).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(10)
            .background(selected ? Theme.navSelected : Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PowerCard: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var preview = LEDEngine.shared.preview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(tr("Consumo"))
            SwitchRow(title: tr("Limitar consumo"),
                      detail: tr("Baja el brillo de toda la tira si el consumo estimado pasa del límite. Ponlo un poco por debajo de lo que da tu fuente (el USB del Mac da 500 mA)."),
                      isOn: $settings.powerLimitEnabled)
            if settings.powerLimitEnabled {
                SliderRow(title: tr("Límite"), value: Binding(
                    get: { Double(settings.powerLimitMilliamps) },
                    set: { settings.powerLimitMilliamps = Int($0) }), range: 200...10000, step: 100) { "\(Int($0)) mA" }
            }
            HStack(spacing: 8) {
                Text(tr("Consumo estimado ahora"))
                Spacer()
                if preview.powerLimited {
                    Text(tr("Limitado")).font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: 0x3A2F18), in: Capsule())
                        .foregroundStyle(Theme.warn)
                }
                Text("\(Int(LEDEngine.shared.preview.milliamps.rounded())) mA").monospacedText()
            }
            Text(tr("Estimación para WS2812B: unos 20 mA por color a tope (60 mA en blanco) más 1 mA por LED."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .ledlyCard()
    }
}

private struct FirmwareCard: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(tr("Firmware"))
            Text(tr("Instala en el Nano el programa que recibe los colores. Solo hace falta una vez, o al cambiar de pin."))
                .foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Picker(tr("Pin de datos"), selection: $settings.dataPin) {
                    ForEach(Firmware.pins, id: \.self) { Text("D\($0)").tag($0) }
                }
                .frame(width: 200)
                Spacer()
                Button {
                    if let path = settings.portPath { engine.installFirmware(pin: settings.dataPin, path: path) }
                } label: {
                    Label(tr("Instalar firmware"), systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.ledlyPrimary)
                .disabled(settings.portPath == nil || isRunning)
            }
            switch engine.flashState {
            case .idle:
                EmptyView()
            case .running(let step):
                VStack(alignment: .leading, spacing: 6) {
                    Text(stepText(step)).foregroundStyle(Theme.text2)
                    ProgressView(value: stepProgress(step)).tint(Theme.accent)
                }
            case .done:
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
                    Text(tr("Firmware instalado en el pin D%d.", settings.dataPin))
                    Spacer()
                    Button(tr("Vale")) { engine.resetFlashState() }.buttonStyle(.ledlyGhost)
                }
            case .failed(let message):
                HStack(alignment: .top) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(tr("Vale")) { engine.resetFlashState() }.buttonStyle(.ledlyGhost)
                }
            }
        }
        .ledlyCard()
    }

    private var isRunning: Bool {
        if case .running = engine.flashState { return true }
        return false
    }

    private func stepText(_ step: Flasher.Step) -> String {
        switch step {
        case .connecting: return tr("Conectando con el bootloader…")
        case .backingUp(let p): return tr("Guardando copia del firmware actual… %d %%", Int(p * 100))
        case .writing(let p): return tr("Escribiendo… %d %%", Int(p * 100))
        case .verifying(let p): return tr("Verificando… %d %%", Int(p * 100))
        case .done: return tr("Listo")
        }
    }

    private func stepProgress(_ step: Flasher.Step) -> Double {
        switch step {
        case .connecting: return 0
        case .backingUp(let p): return p * 0.3
        case .writing(let p): return 0.3 + p * 0.4
        case .verifying(let p): return 0.7 + p * 0.3
        case .done: return 1
        }
    }
}

// MARK: - Image

struct ImagePane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var displays: [(CGDirectDisplayID, String)] = []
    @State private var showWhiteBalance = false

    var body: some View {
        Pane(title: tr("Imagen"), subtitle: tr("Cómo se captura la pantalla y cómo se corrigen los colores antes de enviarlos.")) {
            CaptureViewer()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(tr("Captura"))
                CaptureTargetPicker()
                Picker(settings.captureApp == nil ? tr("Pantalla") : tr("Pantalla si la app no tiene ventanas"), selection: $settings.displayID) {
                    Text(tr("Principal")).tag(UInt32(0))
                    ForEach(displays, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker(tr("Fotogramas por segundo"), selection: $settings.captureFPS) {
                    ForEach([15, 20, 30, 45, 60], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker(tr("Cálculo del color"), selection: $settings.sampling) {
                    ForEach(SamplingMode.allCases) { Text($0.title).tag($0) }
                }
                SwitchRow(title: tr("Detectar bordes negros"),
                          detail: tr("Ignora las franjas negras de películas y vídeos para que los LEDs de arriba y abajo no se apaguen."),
                          isOn: $settings.blackBorders)
            }
            .ledlyCard()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel(tr("Color"))
                    Spacer()
                    Button(tr("Balance de blancos…")) { showWhiteBalance = true }.buttonStyle(.ledlySecondary)
                    Button(tr("Restablecer")) { settings.resetImage() }.buttonStyle(.ledlyGhost)
                }
                SliderRow(title: tr("Suavizado"), value: $settings.smoothingMs, range: 0...1000, step: 10) { "\(Int($0)) ms" }
                HStack {
                    Text(tr("Tipo de suavizado"))
                    Spacer()
                    SegmentedControl(options: SmoothingKind.allCases.map { ($0.title, $0) }, selection: $settings.smoothing)
                }
                SwitchRow(title: tr("Anti-parpadeo"),
                          detail: tr("Evita que los LEDs tiemblen entre dos niveles en escenas oscuras."),
                          isOn: $settings.antiFlicker)
                SliderRow(title: tr("Gamma"), value: $settings.gamma, range: 0.5...3)
                SliderRow(title: tr("Saturación"), value: $settings.saturation, range: 0...2)
                SliderRow(title: tr("Temperatura"), value: $settings.temperature, range: 2500...10000, step: 100) { "\(Int($0)) K" }
                SliderRow(title: tr("Luz mínima"), value: $settings.backlight, range: 0...0.2) { "\(Int(($0 * 100).rounded())) %" }
                SliderRow(title: tr("Rojo"), value: $settings.redGain, range: 0...1)
                SliderRow(title: tr("Verde"), value: $settings.greenGain, range: 0...1)
                SliderRow(title: tr("Azul"), value: $settings.blueGain, range: 0...1)
            }
            .ledlyCard()

            CalibrationCard()
        }
        .sheet(isPresented: $showWhiteBalance) {
            WhiteBalanceWizard { showWhiteBalance = false }
        }
        .task {
            displays = NSScreen.screens.compactMap { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
                return (id, screen.localizedName)
            }
        }
    }
}

/// Advanced calibration: target color per corner of the RGB cube, each one testable on the strip.
private struct CalibrationCard: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = LEDEngine.shared
    @State private var testing: CalibrationCorner?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Calibración avanzada"))
                Spacer()
                Button(tr("Restablecer")) {
                    settings.calibration.targets = [:]
                    if let testing { test(testing) }
                }
                .buttonStyle(.ledlyGhost)
                .disabled(settings.calibration.isIdentity)
            }
            SwitchRow(title: tr("Activar calibración avanzada"),
                      detail: tr("Corrige cómo saca la tira cada color. Pulsa «Probar», compara el LED con la muestra de la pantalla y ajusta el color de la derecha hasta que se parezcan. Los colores intermedios se ajustan solos."),
                      isOn: $settings.calibration.enabled)
            if settings.calibration.enabled {
                ForEach(CalibrationCorner.allCases) { corner in
                    row(corner)
                }
                if testing != nil {
                    Button(tr("Terminar prueba")) { stopTest() }.buttonStyle(.ledlyPrimary)
                }
            }
        }
        .ledlyCard()
        .onDisappear { stopTest() }
        .onChange(of: settings.calibration.enabled) { _, on in if !on { stopTest() } }
    }

    private func row(_ corner: CalibrationCorner) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5).fill(corner.input.swiftUI)
                .frame(width: 34, height: 22)
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.lineStrong) }
                .help(tr("Color en pantalla"))
            Text(corner.title).frame(width: 90, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(Theme.text3)
            ColorPicker("", selection: binding(corner), supportsOpacity: false).labelsHidden()
                .help(tr("Color que debe dar la tira"))
            Text(settings.calibration.target(corner).hex).monospacedText(size: 11).foregroundStyle(Theme.text3)
            Spacer()
            if settings.calibration.target(corner) != corner.input {
                IconButton(symbol: "arrow.uturn.backward", label: tr("Restablecer")) {
                    settings.calibration.setTarget(corner.input, for: corner)
                    if testing == corner { test(corner) }
                }
            }
            Button(testing == corner ? tr("Probando") : tr("Probar")) { test(corner) }
                .buttonStyle(SelectableButtonStyle(selected: testing == corner))
        }
    }

    private func binding(_ corner: CalibrationCorner) -> Binding<Color> {
        Binding(
            get: { settings.calibration.target(corner).swiftUI },
            set: { color in
                guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                settings.calibration.setTarget(RGB(r: Float(ns.redComponent), g: Float(ns.greenComponent),
                                                   b: Float(ns.blueComponent)), for: corner)
                // Keep the strip showing the corner being tuned.
                test(corner)
            })
    }

    private func test(_ corner: CalibrationCorner) {
        testing = corner
        // The engine re-applies the pattern every frame, so target changes show as soon as they arrive.
        engine.testPattern = .calibration(corner.input)
    }

    private func stopTest() {
        if case .calibration = engine.testPattern { engine.testPattern = nil }
        testing = nil
    }
}

// MARK: - API

struct APIPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var server = APIServer.shared
    @State private var portText = ""
    @State private var ddpPortText = ""
    @ObservedObject private var engine = LEDEngine.shared

    var body: some View {
        Pane(title: tr("API"), subtitle: tr("Controla la tira y consulta su estado desde otras apps, scripts o Home Assistant.")) {
            VStack(alignment: .leading, spacing: 8) {
                SwitchRow(title: tr("Activar API"), detail: statusText, isOn: $settings.apiEnabled)
                HStack {
                    Text(tr("Puerto"))
                    Spacer()
                    LedlyTextField(placeholder: "8765", text: $portText) {
                        if let port = Int(portText), (1...65535).contains(port) { settings.apiPort = port }
                    }
                    .frame(width: 100)
                }
                SwitchRow(title: tr("Solo este Mac"), detail: tr("Rechaza conexiones de otros equipos de la red."), isOn: $settings.apiLocalOnly)
                SwitchRow(title: tr("Anunciar como WLED"),
                          detail: tr("Home Assistant y las apps de WLED la encuentran solas en la red."),
                          isOn: $settings.wledDiscovery)
                HStack {
                    Text(tr("Token (opcional)"))
                    Spacer()
                    LedlyTextField(placeholder: tr("sin token"), text: $settings.apiToken).frame(width: 240)
                }
                Text(tr("Con token, /api pide «Authorization: Bearer <token>». La parte compatible con WLED sigue abierta."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            .ledlyCard()

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(tr("Tiempo real (DDP)"))
                SwitchRow(title: tr("Recibir fotogramas por DDP"),
                          detail: ddpText,
                          isOn: $settings.ddpEnabled)
                HStack {
                    Text(tr("Puerto UDP"))
                    Spacer()
                    LedlyTextField(placeholder: "4048", text: $ddpPortText) {
                        if let port = Int(ddpPortText), (1...65535).contains(port) { settings.ddpPort = port }
                    }
                    .frame(width: 100)
                }
                Text(tr("Al llegar fotogramas, mandan sobre la pantalla, los efectos, el color y los avisos. Si dejan de llegar 2,5 s, vuelve a lo que había. Se aplican el brillo, la temperatura y el límite de consumo. Sin token, como en WLED."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            .ledlyCard()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(tr("Direcciones"))
                ForEach(addresses, id: \.self) { url in
                    HStack {
                        Text(url).monospacedText()
                        Spacer()
                        IconButton(symbol: "doc.on.doc", label: tr("Copiar")) { copy(url) }
                    }
                }
            }
            .ledlyCard()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(tr("Ejemplos"))
                ForEach(examples, id: \.0) { title, command in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).foregroundStyle(Theme.text2)
                        HStack(alignment: .top) {
                            Text(command).monospacedText(size: 11).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            IconButton(symbol: "doc.on.doc", label: tr("Copiar")) { copy(command) }
                        }
                        .padding(10)
                        .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
                    }
                }
            }
            .ledlyCard()
        }
        .onAppear {
            portText = "\(settings.apiPort)"
            ddpPortText = "\(settings.ddpPort)"
        }
    }

    private var statusText: String {
        switch server.status {
        case .running(let port): return tr("Escuchando en el puerto %d · %d clientes WebSocket", port, server.clients)
        case .stopped: return tr("Desactivada")
        case .failed(let message): return message
        }
    }

    private var ddpText: String {
        if let source = engine.liveSource { return tr("Recibiendo de %@", source) }
        switch server.ddpStatus {
        case .running(let port): return tr("Esperando fotogramas en UDP %d", port)
        case .stopped: return tr("Desactivada")
        case .failed(let message): return message
        }
    }

    private var base: String { "http://localhost:\(settings.apiPort)" }

    private var addresses: [String] {
        var list = [base]
        if !settings.apiLocalOnly {
            list += NetworkAddresses.ipv4().map { "http://\($0):\(settings.apiPort)" }
        }
        return list
    }

    private var auth: String { settings.apiToken.isEmpty ? "" : " -H 'Authorization: Bearer \(settings.apiToken)'" }

    private var examples: [(String, String)] {
        [
            (tr("Estado"), "curl\(auth) \(base)/api/state"),
            (tr("Color fijo"), "curl\(auth) -X POST \(base)/api/state -d '{\"color\":\"#FF2D95\",\"brightness\":60}'"),
            (tr("Efecto"), "curl\(auth) -X POST \(base)/api/state -d '{\"effect\":\"fire\",\"speed\":1.5}'"),
            (tr("Volver a la pantalla"), "curl\(auth) -X POST \(base)/api/state -d '{\"mode\":\"screen\"}'"),
            (tr("Aviso de 3 segundos"), "curl\(auth) -X POST \(base)/api/state -d '{\"effect\":\"strobe\",\"color\":\"#FF0000\",\"duration\":3}'"),
            (tr("Apagar"), "curl\(auth) -X POST \(base)/api/state -d '{\"on\":false}'"),
            (tr("Colores en vivo (WebSocket)"), "websocat ws://localhost:\(settings.apiPort)/api/ws\(settings.apiToken.isEmpty ? "" : "?token=\(settings.apiToken)")  # {\"subscribe\":\"leds\"}"),
            (tr("Soltar el tiempo real"), "curl\(auth) -X POST \(base)/api/state -d '{\"live\":false}'"),
            (tr("WLED"), "curl -X POST \(base)/json/state -d '{\"on\":true,\"bri\":128,\"seg\":[{\"col\":[[0,120,255]]}]}'"),
        ]
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum NetworkAddresses {
    /// IPv4 addresses of the active network interfaces (no loopback).
    static func ipv4() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254") { result.append(ip) }
            }
        }
        return Array(Set(result)).sorted()
    }
}

// MARK: - Settings

struct SettingsPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var localizer = Localizer.shared
    @ObservedObject private var updater = Updater.shared
    @State private var login = LoginItem.isEnabled

    var body: some View {
        Pane(title: tr("Ajustes")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(tr("Idioma"))
                    Spacer()
                    Picker("", selection: $localizer.choice) {
                        ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                SwitchRow(title: tr("Abrir al iniciar sesión"), isOn: Binding(
                    get: { login },
                    set: { LoginItem.setEnabled($0); login = LoginItem.isEnabled }))
                SwitchRow(title: tr("Apagar al dormir"), detail: tr("Apaga la tira cuando el Mac o las pantallas se duermen."),
                          isOn: $settings.offWhenAsleep)
                SwitchRow(title: tr("Buscar actualizaciones automáticamente"), isOn: Binding(
                    get: { updater.autoCheck },
                    set: { updater.autoCheck = $0 }))
            }
            .ledlyCard()
        }
    }
}
