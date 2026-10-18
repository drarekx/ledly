import Combine
import CryptoKit
import Foundation
import Network

/// HTTP + WebSocket API on the local network.
///
/// Native API (`/api/...`) plus a WLED-compatible subset (`/json/...`, `/win`) so Home Assistant,
/// the WLED apps and other WLED clients can drive the strip. See README for the reference.
@MainActor
final class APIServer: ObservableObject {
    static let shared = APIServer()

    enum Status: Equatable {
        case stopped, running(port: Int), failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var clients = 0
    @Published private(set) var ddpStatus: DDPReceiver.Status = .stopped

    private let ddp = DDPReceiver()
    private var lastDDPConfig: (Bool, Int, Bool)?

    private var listener: NWListener?
    private var sockets: [ObjectIdentifier: WebSocketClient] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var lastConfig: (Bool, Int, Bool, Bool)?
    private let queue = DispatchQueue(label: "ledly.api")
    private let startDate = Date()

    func start() {
        ddp.onFrame = { bytes, source in LEDEngine.shared.receiveLive(bytes, from: source) }
        ddp.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.ddpStatus = status }
        }
        LEDEngine.shared.$liveSource.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.broadcastState() } }
            .store(in: &cancellables)
        Settings.shared.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.applySettings()
                self?.broadcastState()
            }
            .store(in: &cancellables)
        LEDEngine.shared.$deviceStatus.dropFirst().removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.broadcastState() } }
            .store(in: &cancellables)
        // Live LED colors for subscribed WebSocket clients, ~15 fps.
        LEDEngine.shared.preview.$colors
            .throttle(for: .milliseconds(66), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] colors in self?.broadcastColors(colors) }
            .store(in: &cancellables)
        applySettings()
    }

    /// DDP follows the API's network policy: "This Mac only" binds it to loopback too.
    private func applyDDP() {
        let s = Settings.shared
        let config = (s.ddpEnabled, s.ddpPort, s.apiLocalOnly)
        if let last = lastDDPConfig, last == config { return }
        lastDDPConfig = config
        if s.ddpEnabled {
            ddp.start(port: s.ddpPort, localOnly: s.apiLocalOnly)
        } else {
            ddp.stop()
            LEDEngine.shared.endLive()
        }
    }

    private func applySettings() {
        applyDDP()
        let s = Settings.shared
        let config = (s.apiEnabled, s.apiPort, s.apiLocalOnly, s.wledDiscovery)
        if let last = lastConfig, last == config { return }
        lastConfig = config
        listener?.cancel()
        listener = nil
        for client in sockets.values { client.close() }
        sockets.removeAll()
        clients = 0
        guard s.apiEnabled else {
            status = .stopped
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if s.apiLocalOnly {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(s.apiPort))!)
            }
            let listener = s.apiLocalOnly
                ? try NWListener(using: parameters)
                : try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: UInt16(s.apiPort))!)
            if s.wledDiscovery && !s.apiLocalOnly {
                listener.service = NWListener.Service(name: "Ledly", type: "_wled._tcp")
            }
            let port = s.apiPort
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.status = .running(port: port)
                    case .failed(let error): self?.status = .failed(error.localizedDescription)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection) {
        let client = HTTPConnection(connection: connection, queue: queue) { [weak self] request, reply in
            DispatchQueue.main.async {
                guard let self else { return }
                if request.isWebSocketUpgrade {
                    self.upgrade(request, connection: connection, reply: reply)
                } else {
                    reply(self.handle(request))
                }
            }
        }
        client.start()
    }

    // MARK: - Routing

    private func handle(_ req: HTTPRequest) -> HTTPResponse {
        if req.method == "OPTIONS" { return HTTPResponse(status: 204) }
        let token = Settings.shared.apiToken
        // WLED clients don't send tokens, so a token only guards the native API.
        let isDocs = req.path == "/api/docs" || req.path == "/api/openapi.json"
        if !token.isEmpty, req.path.hasPrefix("/api"), !isDocs,
           req.headers["authorization"] != "Bearer \(token)", req.query["token"] != token {
            return .json(["error": "unauthorized"], status: 401)
        }
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/api/docs"):
            return HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(APIDocs.html.utf8))
        case ("GET", "/api/openapi.json"):
            return .json(APIDocs.openAPI(port: Settings.shared.apiPort))
        case ("GET", "/api"):
            return .json(apiIndex())
        case ("GET", "/api/state"):
            return .json(nativeState())
        case ("POST", "/api/state"), ("PUT", "/api/state"), ("PATCH", "/api/state"):
            guard let body = req.jsonBody else { return .json(["error": "invalid JSON"], status: 400) }
            if let error = applyNative(body) { return .json(["error": error], status: 400) }
            return .json(nativeState())
        case ("GET", "/api/effects"):
            return .json(EffectKind.ordered.map { ["id": $0.rawValue, "name": $0.title, "usesColor": $0.usesColor] })
        case ("GET", "/api/leds"):
            let colors = LEDEngine.shared.currentColors()
            return .json(["count": colors.count, "colors": colors.map(\.hex)])
        case ("GET", "/api/device"):
            return .json(deviceInfo())
        case ("POST", "/api/device/reconnect"):
            LEDEngine.shared.reconnect()
            return .json(deviceInfo())
        case ("GET", "/api/layout"):
            return .json(layoutJSON())

        // WLED compatibility
        case ("GET", "/json"):
            return .json(["state": wledState(), "info": wledInfo(), "effects": wledEffects(), "palettes": ["Default"]])
        case ("GET", "/json/state"):
            return .json(wledState())
        case ("POST", "/json/state"), ("POST", "/json"):
            guard let body = req.jsonBody else { return .json(["error": 9], status: 400) }
            applyWLED(body)
            if body["v"] as? Bool == true { return .json(wledState()) }
            return .json(["success": true])
        case ("GET", "/json/info"):
            return .json(wledInfo())
        case ("GET", "/json/eff"):
            return .json(wledEffects())
        case ("GET", "/json/pal"):
            return .json(["Default"])
        case ("GET", "/json/si"):
            return .json(["state": wledState(), "info": wledInfo()])
        case ("GET", "/win"):
            applyWLEDQuery(req.query)
            return HTTPResponse(status: 200, contentType: "text/xml", body: Data(wledXML().utf8))
        default:
            return .json(["error": "not found", "path": req.path], status: 404)
        }
    }

    private func apiIndex() -> [String: Any] {
        [
            "name": "Ledly",
            "version": Updater.currentVersion,
            "docs": "/api/docs",
            "openapi": "/api/openapi.json",
            "endpoints": [
                "GET /api/state", "POST /api/state", "GET /api/effects", "GET /api/leds",
                "GET /api/device", "POST /api/device/reconnect", "GET /api/layout", "WS /api/ws",
                "GET /api/docs", "GET /api/openapi.json", "WS /ws (WLED)",
                "GET /json (WLED)", "POST /json/state (WLED)",
            ],
        ]
    }

    // MARK: - Native API

    func nativeState() -> [String: Any] {
        let s = Settings.shared
        let engine = LEDEngine.shared
        return [
            "on": s.isOn,
            "mode": s.mode.rawValue,
            "effect": s.effect.rawValue,
            "speed": s.effectSpeed,
            "equalizer": ["layout": s.equalizer.layout.rawValue, "style": s.equalizer.style.rawValue,
                          "colors": s.equalizer.colors.rawValue, "sensitivity": s.equalizer.sensitivity],
            "color": s.colorHex,
            "brightness": Int((s.brightness * 100).rounded()),
            "overlay": engine.overlayActive,
            "live": engine.liveSource != nil,
            "liveSource": engine.liveSource ?? NSNull(),
            "leds": s.layout.count,
            "fps": (engine.fps * 10).rounded() / 10,
            "power": ["milliamps": Int(LEDEngine.shared.preview.milliamps.rounded()), "limited": LEDEngine.shared.preview.powerLimited,
                      "limit": Settings.shared.powerLimitEnabled ? Settings.shared.powerLimitMilliamps : 0],
            "device": deviceInfo(),
            "capture": captureStatusText(engine.grabberStatus),
            "captureSource": engine.captureSource,
            "audio": engine.audioLevels().map { a -> [String: Any] in
                ["level": (Double(a.level) * 100).rounded() / 100, "bass": (Double(a.bass) * 100).rounded() / 100,
                 "bands": a.bands.map { (Double($0) * 100).rounded() / 100 },
                 "lastBeat": a.lastBeat == .distantPast ? NSNull() : ISO8601DateFormatter().string(from: a.lastBeat) as Any]
            } ?? NSNull(),
        ]
    }

    /// Returns an error message, or nil when applied.
    private func applyNative(_ body: [String: Any]) -> String? {
        let s = Settings.shared
        var mode: LightMode?
        if let value = body["mode"] as? String {
            guard let m = LightMode(rawValue: value) else { return "unknown mode \(value)" }
            mode = m
        }
        var effect: EffectKind?
        if let value = body["effect"] as? String {
            guard let e = EffectKind(rawValue: value) else { return "unknown effect \(value)" }
            effect = e
            if mode == nil { mode = .effect }
        }
        var color: RGB?
        if let value = body["color"] {
            guard let c = Self.parseColor(value) else { return "color must be \"#RRGGBB\" or [r,g,b]" }
            color = c
            if mode == nil && effect == nil { mode = .color }
        }
        var equalizer: EqualizerOptions?
        if let value = body["equalizer"] as? [String: Any] {
            var options = s.equalizer
            if let preset = value["preset"] as? String {
                guard let match = EqualizerOptions.presets.first(where: { $0.id == preset }) else { return "unknown preset \(preset)" }
                options.layout = match.options.layout
                options.style = match.options.style
                options.colors = match.options.colors
            }
            if let raw = value["layout"] as? String {
                guard let v = EqualizerLayout(rawValue: raw) else { return "unknown layout \(raw)" }
                options.layout = v
            }
            if let raw = value["style"] as? String {
                guard let v = EqualizerStyle(rawValue: raw) else { return "unknown style \(raw)" }
                options.style = v
            }
            if let raw = value["colors"] as? String {
                guard let v = EqualizerColors(rawValue: raw) else { return "unknown colors \(raw)" }
                options.colors = v
            }
            if let v = Self.number(value["sensitivity"]) { options.sensitivity = min(max(v, 0.5), 2.5) }
            equalizer = options
            // Setting the equalizer shows it.
            if effect == nil { effect = .musicSpectrum; if mode == nil { mode = .effect } }
        }
        // `duration` (seconds): show it for a while, then go back to what was on.
        if let duration = Self.number(body["duration"]), duration > 0 {
            LEDEngine.shared.showOverlay(mode: mode ?? .color, effect: effect, color: color, duration: min(duration, 3600))
            return nil
        }
        if body["clear"] as? Bool == true { LEDEngine.shared.clearOverlay() }
        if let live = body["live"] as? Bool {
            guard !live else { return "real-time mode starts by itself when DDP frames arrive" }
            LEDEngine.shared.endLive()
        }
        if let on = body["on"] as? Bool { s.isOn = on }
        if body["toggle"] as? Bool == true { s.isOn.toggle() }
        if let mode { s.mode = mode }
        if let effect { s.effect = effect }
        if let equalizer { s.equalizer = equalizer }
        if let color { s.color = color }
        if let speed = Self.number(body["speed"]) { s.effectSpeed = min(max(speed, 0.1), 3) }
        if let brightness = Self.number(body["brightness"]) { s.brightness = min(max(brightness / 100, 0), 1) }
        if (mode != nil || color != nil || effect != nil) && body["on"] == nil { s.isOn = true }
        return nil
    }

    private func deviceInfo() -> [String: Any] {
        let s = Settings.shared
        var info: [String: Any] = ["port": s.portPath ?? NSNull(), "pin": s.dataPin]
        switch LEDEngine.shared.deviceStatus {
        case .disconnected: info["status"] = "disconnected"
        case .connecting: info["status"] = "connecting"
        case .connected(let firmware):
            info["status"] = "connected"
            info["firmware"] = firmware ?? NSNull()
        case .failed(let message):
            info["status"] = "error"
            info["error"] = message
        }
        return info
    }

    private func layoutJSON() -> [String: Any] {
        let l = Settings.shared.layout
        return [
            "top": l.top, "right": l.right, "bottom": l.bottom, "left": l.left,
            "start": l.start.rawValue, "clockwise": l.clockwise, "offset": l.offset,
            "bottomGap": l.bottomGap, "count": l.count,
        ]
    }

    private func captureStatusText(_ status: ScreenGrabber.Status) -> String {
        switch status {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .noPermission: return "no-permission"
        case .failed(let message): return "error: \(message)"
        }
    }

    // MARK: - WLED compatibility

    /// WLED effect ids: 0 = Solid (color mode), then ours, then "Ambilight" (screen mode).
    private var wledEffectNames: [String] {
        ["Solid"] + EffectKind.allCases.map { trEnglish($0.titleKey) } + ["Ambilight"]
    }

    private var wledFX: Int {
        let s = Settings.shared
        switch s.mode {
        case .color: return 0
        case .effect: return (EffectKind.allCases.firstIndex(of: s.effect) ?? 0) + 1
        case .screen: return EffectKind.allCases.count + 1
        }
    }

    private func setWLEDFX(_ fx: Int) {
        let s = Settings.shared
        if fx == 0 {
            s.mode = .color
        } else if fx <= EffectKind.allCases.count {
            s.effect = EffectKind.allCases[fx - 1]
            s.mode = .effect
        } else if fx == EffectKind.allCases.count + 1 {
            s.mode = .screen
        }
    }

    private func wledEffects() -> [String] { wledEffectNames }

    private func wledState() -> [String: Any] {
        let s = Settings.shared
        let c = s.color
        let count = s.layout.count
        let speed = Int(((s.effectSpeed - 0.1) / 2.9 * 255).rounded())
        return [
            "on": s.isOn,
            "bri": Int((s.brightness * 255).rounded()),
            "transition": 7,
            "ps": -1, "pl": -1,
            "nl": ["on": false, "dur": 60, "mode": 1, "tbri": 0, "rem": -1],
            "udpn": ["send": false, "recv": false],
            "lor": 0,
            "live": LEDEngine.shared.liveSource != nil,
            "mainseg": 0,
            "seg": [[
                "id": 0, "start": 0, "stop": count, "len": count, "grp": 1, "spc": 0, "of": 0,
                "on": s.isOn, "frz": false, "bri": 255, "cct": 127,
                "col": [[c.r8, c.g8, c.b8], [0, 0, 0], [0, 0, 0]],
                "fx": wledFX, "sx": speed, "ix": 128, "pal": 0, "c1": 128, "c2": 128, "c3": 16,
                "sel": true, "rev": false, "mi": false, "o1": false, "o2": false, "o3": false, "si": 0, "m12": 0,
            ] as [String: Any]],
        ]
    }

    private func wledInfo() -> [String: Any] {
        let s = Settings.shared
        let mac = s.deviceID
        return [
            "ver": "0.14.4",
            "vid": 2405180,
            "leds": ["count": s.layout.count, "pwr": Int(LEDEngine.shared.preview.milliamps.rounded()), "fps": Int(LEDEngine.shared.fps), "maxpwr": s.powerLimitEnabled ? s.powerLimitMilliamps : 0, "maxseg": 1,
                     "rgbw": false, "wv": 0, "cct": 0, "seglc": [1], "lc": 1],
            "str": false,
            "name": "Ledly",
            "udpport": 21324,
            "live": LEDEngine.shared.liveSource != nil,
            "liveseg": -1,
            "lm": LEDEngine.shared.liveSource != nil ? "DDP" : "",
            "lip": LEDEngine.shared.liveSource ?? "",
            "ws": clients,
            "fxcount": wledEffectNames.count,
            "palcount": 1,
            "cpalcount": 0,
            "maps": [["id": 0]],
            "wifi": ["bssid": "", "rssi": 0, "signal": 100, "channel": 0],
            "fs": ["u": 0, "t": 0, "pmt": 0],
            "ndc": 0,
            "arch": "macos",
            "core": "Ledly \(Updater.currentVersion)",
            "lwip": 0,
            "freeheap": 100_000,
            "uptime": Int(Date().timeIntervalSince(startDate)),
            "time": ISO8601DateFormatter().string(from: Date()),
            "opt": 0,
            "brand": "WLED",
            "product": "Ledly",
            "mac": mac,
            "ip": "",
        ]
    }

    private func applyWLED(_ body: [String: Any]) {
        let s = Settings.shared
        // WLED leaves real-time mode with {"live": false}.
        if body["live"] as? Bool == false { LEDEngine.shared.endLive() }
        if let on = body["on"] as? Bool { s.isOn = on }
        if body["on"] as? String == "t" { s.isOn.toggle() }
        if let bri = Self.number(body["bri"]) {
            s.brightness = min(max(bri / 255, 0), 1)
            if bri > 0 && body["on"] == nil { s.isOn = true }
        }
        let segments: [[String: Any]]
        if let list = body["seg"] as? [[String: Any]] { segments = list }
        else if let one = body["seg"] as? [String: Any] { segments = [one] }
        else { segments = [] }
        for seg in segments {
            if let on = seg["on"] as? Bool { s.isOn = on }
            if let cols = seg["col"] as? [Any], let first = cols.first, let color = Self.parseColor(first) {
                s.color = color
                if seg["fx"] == nil && s.mode == .screen { s.mode = .color }
            }
            if let fx = Self.number(seg["fx"]) { setWLEDFX(Int(fx)) }
            if let sx = Self.number(seg["sx"]) { s.effectSpeed = 0.1 + sx / 255 * 2.9 }
        }
    }

    /// Legacy HTTP API: /win&T=1&A=128&R=255&G=0&B=0&FX=3
    private func applyWLEDQuery(_ q: [String: String]) {
        let s = Settings.shared
        if let t = q["T"] { s.isOn = t == "2" ? !s.isOn : t == "1" }
        if let a = q["A"].flatMap(Double.init) { s.brightness = min(max(a / 255, 0), 1) }
        if let r = q["R"].flatMap(Int.init) ?? Optional(s.color.r8),
           let g = q["G"].flatMap(Int.init) ?? Optional(s.color.g8),
           let b = q["B"].flatMap(Int.init) ?? Optional(s.color.b8),
           q["R"] != nil || q["G"] != nil || q["B"] != nil {
            s.color = RGB(r8: r, g8: g, b8: b)
        }
        if let fx = q["FX"].flatMap(Int.init) { setWLEDFX(fx) }
        if let sx = q["SX"].flatMap(Double.init) { s.effectSpeed = 0.1 + sx / 255 * 2.9 }
    }

    private func wledXML() -> String {
        let s = Settings.shared
        let c = s.color
        return "<?xml version=\"1.0\" ?><vs><ac>\(s.isOn ? Int(s.brightness * 255) : 0)</ac><cl>\(c.r8)</cl><cl>\(c.g8)</cl><cl>\(c.b8)</cl><fx>\(wledFX)</fx><sx>\(Int((s.effectSpeed - 0.1) / 2.9 * 255))</sx><ds>Ledly</ds></vs>"
    }

    // MARK: - WebSocket

    private func upgrade(_ req: HTTPRequest, connection: NWConnection, reply: @escaping (HTTPResponse) -> Void) {
        guard req.path == "/ws" || req.path == "/api/ws", let key = req.headers["sec-websocket-key"] else {
            reply(.json(["error": "not found"], status: 404))
            return
        }
        // `/ws` is WLED's socket and stays open like the rest of the WLED API; `/api/ws` needs the token.
        let token = Settings.shared.apiToken
        if !token.isEmpty, req.path == "/api/ws", req.query["token"] != token {
            reply(.json(["error": "unauthorized"], status: 401))
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        var response = HTTPResponse(status: 101)
        response.headers["Upgrade"] = "websocket"
        response.headers["Connection"] = "Upgrade"
        response.headers["Sec-WebSocket-Accept"] = accept
        response.keepOpen = true
        reply(response)

        let client = WebSocketClient(connection: connection, queue: queue)
        let id = ObjectIdentifier(client)
        client.onText = { [weak self] text in
            DispatchQueue.main.async { self?.received(text, from: id) }
        }
        client.onClose = { [weak self] in
            DispatchQueue.main.async {
                self?.sockets[id] = nil
                self?.clients = self?.sockets.count ?? 0
                self?.countListeners()
            }
        }
        sockets[id] = client
        clients = sockets.count
        client.start()
        client.send(text: jsonString(["state": nativeState(), "wled": ["state": wledState(), "info": wledInfo()]]))
    }

    /// Messages: {"subscribe":"leds"}, {"unsubscribe":"leds"}, or any /api/state or WLED /json/state body.
    private func received(_ text: String, from id: ObjectIdentifier) {
        guard let client = sockets[id],
              let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        if body["subscribe"] as? String == "leds" { client.wantsLEDs = true; countListeners(); return }
        if body["unsubscribe"] as? String == "leds" { client.wantsLEDs = false; countListeners(); return }
        if body["seg"] != nil || body["bri"] != nil || body["v"] != nil || body["lor"] != nil {
            applyWLED(body)
        } else if let error = applyNative(body) {
            client.send(text: jsonString(["error": error]))
        }
    }

    private func countListeners() {
        LEDEngine.shared.preview.listeners = sockets.values.filter(\.wantsLEDs).count
    }

    private func broadcastState() {
        guard !sockets.isEmpty else { return }
        let text = jsonString(["state": nativeState(), "wled": ["state": wledState(), "info": wledInfo()]])
        for client in sockets.values { client.send(text: text) }
    }

    private func broadcastColors(_ colors: [RGB]) {
        let listeners = sockets.values.filter(\.wantsLEDs)
        guard !listeners.isEmpty else { return }
        let text = jsonString(["leds": colors.map(\.hex)])
        for client in listeners { client.send(text: text) }
    }

    // MARK: - Helpers

    static func parseColor(_ value: Any) -> RGB? {
        if let text = value as? String { return RGB(hex: text) }
        if let list = value as? [Any], list.count >= 3,
           let r = number(list[0]), let g = number(list[1]), let b = number(list[2]) {
            return RGB(r8: Int(r), g8: Int(g), b8: Int(b))
        }
        if let dict = value as? [String: Any], let r = number(dict["r"]), let g = number(dict["g"]), let b = number(dict["b"]) {
            return RGB(r8: Int(r), g8: Int(g), b8: Int(b))
        }
        return nil
    }

    static func number(_ value: Any?) -> Double? {
        // JSON booleans are NSNumbers too; `is Bool` would also match 0 and 1.
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - HTTP

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body.isEmpty ? Data("{}".utf8) : body)) as? [String: Any]
    }

    var isWebSocketUpgrade: Bool { headers["upgrade"]?.lowercased() == "websocket" }
}

struct HTTPResponse {
    var status: Int
    var contentType = "application/json"
    var body = Data()
    var headers: [String: String] = [:]
    /// The connection stays open afterwards (WebSocket upgrade).
    var keepOpen = false

    init(status: Int, contentType: String = "application/json", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: Data(jsonString(object).utf8))
    }

    func serialized() -> Data {
        let reasons = [101: "Switching Protocols", 200: "OK", 204: "No Content", 400: "Bad Request",
                       401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "OK")\r\n"
        var all = headers
        if status != 101 {
            all["Content-Type"] = contentType
            all["Content-Length"] = "\(body.count)"
            all["Connection"] = "close"
            all["Access-Control-Allow-Origin"] = "*"
            all["Access-Control-Allow-Methods"] = "GET, POST, PUT, PATCH, OPTIONS"
            all["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
        }
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// One HTTP request per connection (Connection: close), or the start of a WebSocket.
final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private var buffer = Data()
    private var selfRetain: HTTPConnection?

    init(connection: NWConnection, queue: DispatchQueue,
         handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
    }

    func start() {
        selfRetain = self
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.selfRetain = nil }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 1_000_000 {
                self.respond(.json(["error": "too large"], status: 413))
                return
            }
            if let request = self.parse() {
                self.handler(request) { response in self.respond(response) }
            } else if complete || error != nil {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    private func respond(_ response: HTTPResponse) {
        connection.send(content: response.serialized(), completion: .contentProcessed { [weak self] _ in
            if !response.keepOpen { self?.finish() } else { self?.selfRetain = nil }
        })
    }

    private func finish() {
        connection.cancel()
        selfRetain = nil
    }

    private func parse() -> HTTPRequest? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let body = buffer[bodyStart..<(bodyStart + length)]
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        // WLED's legacy API writes parameters as /win&T=1&A=128.
        if let amp = path.firstIndex(of: "&") {
            for pair in path[path.index(after: amp)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                query[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
            }
            path = String(path[..<amp])
        }
        if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: Data(body))
    }
}

/// Minimal RFC 6455 server side: text frames, ping/pong, close.
final class WebSocketClient {
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var wantsLEDs = false

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.markClosed()
            default: break
            }
        }
        receive()
    }

    func send(text: String) {
        send(opcode: 0x1, payload: Data(text.utf8))
    }

    func close() {
        send(opcode: 0x8, payload: Data())
        connection.cancel()
    }

    private func markClosed() {
        guard !closed else { return }
        closed = true
        onClose?()
    }

    private func send(opcode: UInt8, payload: Data) {
        guard !closed else { return }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drainFrames()
            if complete || error != nil {
                self.connection.cancel()
                self.markClosed()
            } else if !self.closed {
                self.receive()
            }
        }
    }

    private func drainFrames() {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(14))
            let opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = (2..<10).reduce(0) { $0 << 8 | Int(bytes[$1]) }
                offset = 10
            }
            let maskOffset = offset
            if masked { offset += 4 }
            guard buffer.count >= offset + length, length < 1_000_000 else { return }
            let start = buffer.startIndex
            var payload = [UInt8](buffer[(start + offset)..<(start + offset + length)])
            if masked {
                let mask = [UInt8](buffer[(start + maskOffset)..<(start + maskOffset + 4)])
                for i in payload.indices { payload[i] ^= mask[i % 4] }
            }
            buffer.removeFirst(offset + length)
            switch opcode {
            case 0x1: onText?(String(decoding: payload, as: UTF8.self))
            case 0x8:
                close()
                markClosed()
                return
            case 0x9: send(opcode: 0xA, payload: Data(payload))
            default: break
            }
        }
    }
}
