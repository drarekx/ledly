import Foundation

/// API reference served by the API itself: `GET /api/openapi.json` (OpenAPI 3.0) and
/// `GET /api/docs` (an HTML page that renders that spec and can try every endpoint).
enum APIDocs {
    @MainActor
    static func openAPI(port: Int) -> [String: Any] {
        let ddpPort = Settings.shared.ddpPort
        let effectIDs = EffectKind.allCases.map(\.rawValue)
        let colorSchema: [String: Any] = [
            "description": "\"#RRGGBB\", [r,g,b] o {\"r\":…,\"g\":…,\"b\":…} (0–255)",
            "oneOf": [
                ["type": "string", "pattern": "^#?[0-9A-Fa-f]{6}$", "example": "#FF2D95"],
                ["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 255], "minItems": 3, "maxItems": 3],
                ["type": "object", "properties": ["r": ["type": "integer"], "g": ["type": "integer"], "b": ["type": "integer"]]],
            ],
        ]
        let device: [String: Any] = [
            "type": "object",
            "properties": [
                "status": ["type": "string", "enum": ["disconnected", "connecting", "connected", "error"]],
                "port": ["type": "string", "nullable": true, "example": "/dev/cu.usbserial-3110"],
                "pin": ["type": "integer", "example": 6],
                "firmware": ["type": "string", "nullable": true, "example": "Ada Ledly 1 pin 6 max 400"],
                "error": ["type": "string"],
            ],
        ]
        let state: [String: Any] = [
            "type": "object",
            "properties": [
                "on": ["type": "boolean"],
                "mode": ["type": "string", "enum": LightMode.allCases.map(\.rawValue)],
                "effect": ["type": "string", "enum": effectIDs],
                "speed": ["type": "number", "minimum": 0.1, "maximum": 3],
                "equalizer": ["$ref": "#/components/schemas/Equalizer"],
                "color": ["type": "string", "example": "#FF8A3D"],
                "brightness": ["type": "integer", "minimum": 0, "maximum": 100],
                "overlay": ["type": "boolean", "description": "Hay un aviso temporal (`duration`) en pantalla."],
                "live": ["type": "boolean", "description": "Se están mostrando fotogramas recibidos por DDP (tiempo real)."],
                "liveSource": ["type": "string", "nullable": true, "description": "Dirección de quien manda los fotogramas."],
                "leds": ["type": "integer", "description": "LEDs de la disposición."],
                "fps": ["type": "number", "description": "Fotogramas por segundo que llegan a la tira."],
                "capture": ["type": "string", "description": "stopped, starting, running, no-permission o error: …"],
                "captureSource": ["type": "string", "description": "Qué se captura: la pantalla o la ventana de la app elegida en Imagen → Capturar."],
                "audio": ["type": "object", "nullable": true,
                          "description": "Audio del sistema que ven los efectos de música (null si no hay ninguno activo): `level`, `bass` y 16 `bands` de 0 a 1, y `lastBeat`."],
                "power": ["type": "object", "description": "Consumo estimado de la tira.", "properties": [
                    "milliamps": ["type": "integer"],
                    "limited": ["type": "boolean", "description": "El limitador está bajando el brillo."],
                    "limit": ["type": "integer", "description": "Límite en mA; 0 = sin límite."],
                ]],
                "device": ["$ref": "#/components/schemas/Device"],
            ],
        ]
        let change: [String: Any] = [
            "type": "object",
            "description": "Todo es opcional. Mandar solo `color` pasa a modo color; solo `effect`, a modo efecto. Cambiar modo, color o efecto enciende la tira salvo que se mande `on`.",
            "properties": [
                "on": ["type": "boolean"],
                "toggle": ["type": "boolean", "description": "Invierte el encendido."],
                "mode": ["type": "string", "enum": LightMode.allCases.map(\.rawValue)],
                "effect": ["type": "string", "enum": effectIDs],
                "speed": ["type": "number", "minimum": 0.1, "maximum": 3, "description": "1 = normal."],
                "color": ["$ref": "#/components/schemas/Color"],
                "equalizer": ["$ref": "#/components/schemas/Equalizer"],
                "brightness": ["type": "number", "minimum": 0, "maximum": 100],
                "duration": ["type": "number", "minimum": 0, "maximum": 3600,
                             "description": "Segundos. Muestra el color o efecto ese tiempo y vuelve a lo que había (avisos). No cambia los ajustes guardados."],
                "clear": ["type": "boolean", "description": "Quita el aviso temporal en curso."],
                "live": ["type": "boolean", "enum": [false],
                         "description": "`false` suelta el tiempo real al momento; los paquetes que lleguen en el siguiente segundo se ignoran (los que venían con retraso). El tiempo real empieza solo al llegar fotogramas DDP."],
            ],
            "example": ["effect": "fire", "speed": 1.5, "brightness": 70],
        ]
        func json(_ schema: Any, _ description: String = "OK") -> [String: Any] {
            ["description": description, "content": ["application/json": ["schema": schema]]]
        }
        let errorResponse = json(["type": "object", "properties": ["error": ["type": "string"]]], "Petición no válida")
        let unauthorized = json(["type": "object", "properties": ["error": ["type": "string", "example": "unauthorized"]]], "Falta el token o no coincide")
        let ref = { (name: String) in ["$ref": "#/components/schemas/\(name)"] }

        return [
            "openapi": "3.0.3",
            "info": [
                "title": "Ledly API",
                "version": Updater.currentVersion,
                "description": """
                Controla la tira de LEDs de Ledly y consulta su estado.

                - **Autenticación**: si hay token en Ajustes → API, las rutas `/api/*` piden `Authorization: Bearer <token>` o `?token=<token>`. La documentación, `/ws` y la parte WLED quedan abiertas.
                - **CORS** abierto: se puede llamar desde cualquier página web.
                - **WebSocket** `ws://<host>:\(port)/api/ws` (con `?token=` si hace falta): al conectar envía `{"state":…,"wled":…}` y lo repite en cada cambio. Manda `{"subscribe":"leds"}` para recibir `{"leds":["#RRGGBB",…]}` a ~15 fps (`{"unsubscribe":"leds"}` para parar). También acepta los mismos cuerpos que `POST /api/state`.
                - **Tiempo real (DDP)**: fotogramas por UDP en el puerto \(ddpPort), sin token. Ver la sección «Tiempo real (DDP)» más abajo.
                - **WLED**: `/json/*`, `/win` y el WebSocket `/ws` imitan WLED 0.14 para Home Assistant y las apps de WLED. Efecto 0 = Solid (color), luego los de Ledly en orden, y el último = Ambilight (pantalla).
                """,
            ],
            "servers": [["url": "http://localhost:\(port)"]],
            "x-ddp": ddp(port: ddpPort, apiPort: port),
            "tags": [
                ["name": "Estado", "description": "Encendido, modo, efecto, color y brillo."],
                ["name": "Información", "description": "Efectos, LEDs, dispositivo y disposición."],
                ["name": "WLED", "description": "Compatibilidad con WLED."],
                ["name": "Documentación"],
            ],
            "components": [
                "securitySchemes": ["token": ["type": "http", "scheme": "bearer"]],
                "schemas": [
                    "State": state,
                    "StateChange": change,
                    "Color": colorSchema,
                    "Device": device,
                    "Equalizer": [
                        "type": "object",
                        "description": "Opciones del efecto `musicSpectrum`. Al cambiarlas se muestra el ecualizador. `preset` aplica una combinación y los demás campos la retocan.",
                        "properties": [
                            "preset": ["type": "string", "enum": EqualizerOptions.presets.map(\.id)],
                            "layout": ["type": "string", "enum": EqualizerLayout.allCases.map(\.rawValue)],
                            "style": ["type": "string", "enum": EqualizerStyle.allCases.map(\.rawValue)],
                            "colors": ["type": "string", "enum": EqualizerColors.allCases.map(\.rawValue)],
                            "sensitivity": ["type": "number", "minimum": 0.5, "maximum": 2.5],
                        ],
                    ],
                    "Effect": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string", "enum": effectIDs],
                            "name": ["type": "string"],
                            "usesColor": ["type": "boolean", "description": "El efecto usa el color principal."],
                        ],
                    ],
                    "Layout": [
                        "type": "object",
                        "properties": [
                            "top": ["type": "integer"], "right": ["type": "integer"],
                            "bottom": ["type": "integer"], "left": ["type": "integer"],
                            "start": ["type": "string", "enum": StartCorner.allCases.map(\.rawValue)],
                            "clockwise": ["type": "boolean"], "offset": ["type": "integer"],
                            "bottomGap": ["type": "integer"], "count": ["type": "integer"],
                        ],
                    ],
                ],
            ],
            "security": [["token": []], [:]],
            "paths": [
                "/api/state": [
                    "get": [
                        "tags": ["Estado"], "summary": "Estado actual", "operationId": "getState",
                        "responses": ["200": json(ref("State")), "401": unauthorized],
                    ],
                    "post": [
                        "tags": ["Estado"], "summary": "Cambiar el estado", "operationId": "setState",
                        "description": "También acepta PUT y PATCH. Devuelve el estado resultante.",
                        "requestBody": ["required": true, "content": ["application/json": [
                            "schema": ref("StateChange"),
                            "examples": [
                                "color": ["summary": "Color fijo al 60 %", "value": ["color": "#FF2D95", "brightness": 60]],
                                "efecto": ["summary": "Efecto", "value": ["effect": "fire", "speed": 1.5]],
                                "pantalla": ["summary": "Volver a la pantalla", "value": ["mode": "screen"]],
                                "ecualizador": ["summary": "Ecualizador estéreo en barras", "value": ["equalizer": ["layout": "stereo", "style": "bars", "colors": "heat"]]],
                                "soltar": ["summary": "Soltar el tiempo real (DDP)", "value": ["live": false]],
                                "aviso": ["summary": "Aviso rojo de 3 s", "value": ["effect": "strobe", "color": "#FF0000", "duration": 3]],
                                "apagar": ["summary": "Apagar", "value": ["on": false]],
                            ],
                        ]]],
                        "responses": ["200": json(ref("State")), "400": errorResponse, "401": unauthorized],
                    ],
                ],
                "/api/effects": [
                    "get": [
                        "tags": ["Información"], "summary": "Efectos disponibles", "operationId": "getEffects",
                        "responses": ["200": json(["type": "array", "items": ref("Effect")]), "401": unauthorized],
                    ],
                ],
                "/api/leds": [
                    "get": [
                        "tags": ["Información"], "summary": "Colores que se envían ahora a la tira", "operationId": "getLEDs",
                        "description": "Ya corregidos (brillo, gamma…) y en el orden de la tira.",
                        "responses": ["200": json(["type": "object", "properties": [
                            "count": ["type": "integer"],
                            "colors": ["type": "array", "items": ["type": "string", "example": "#351D0D"]],
                        ]]), "401": unauthorized],
                    ],
                ],
                "/api/device": [
                    "get": [
                        "tags": ["Información"], "summary": "Arduino: puerto, pin, firmware y conexión", "operationId": "getDevice",
                        "responses": ["200": json(ref("Device")), "401": unauthorized],
                    ],
                ],
                "/api/device/reconnect": [
                    "post": [
                        "tags": ["Información"], "summary": "Reconectar con el Arduino", "operationId": "reconnect",
                        "description": "Cierra el puerto y vuelve a abrirlo en el siguiente ciclo (resetea el Nano).",
                        "responses": ["200": json(ref("Device")), "401": unauthorized],
                    ],
                ],
                "/api/layout": [
                    "get": [
                        "tags": ["Información"], "summary": "Disposición de la tira", "operationId": "getLayout",
                        "responses": ["200": json(ref("Layout")), "401": unauthorized],
                    ],
                ],
                "/api": [
                    "get": [
                        "tags": ["Documentación"], "summary": "Índice de rutas", "operationId": "index",
                        "responses": ["200": json(["type": "object"])],
                    ],
                ],
                "/api/openapi.json": [
                    "get": [
                        "tags": ["Documentación"], "summary": "Esta especificación (OpenAPI 3.0)", "operationId": "openapi",
                        "security": [], "responses": ["200": json(["type": "object"])],
                    ],
                ],
                "/api/docs": [
                    "get": [
                        "tags": ["Documentación"], "summary": "Esta página", "operationId": "docs", "security": [],
                        "responses": ["200": ["description": "HTML", "content": ["text/html": ["schema": ["type": "string"]]]]],
                    ],
                ],
                "/json": [
                    "get": [
                        "tags": ["WLED"], "summary": "state + info + effects + palettes", "operationId": "wledAll", "security": [],
                        "responses": ["200": json(["type": "object"])],
                    ],
                    "post": [
                        "tags": ["WLED"], "summary": "Igual que POST /json/state", "operationId": "wledSetAll", "security": [],
                        "requestBody": ["content": ["application/json": ["schema": ["type": "object"],
                                                                         "example": ["on": true, "bri": 128]]]],
                        "responses": ["200": json(["type": "object"])],
                    ],
                ],
                "/json/state": [
                    "get": [
                        "tags": ["WLED"], "summary": "Estado WLED", "operationId": "wledState", "security": [],
                        "responses": ["200": json(["type": "object"])],
                    ],
                    "post": [
                        "tags": ["WLED"], "summary": "Cambiar el estado al estilo WLED", "operationId": "wledSetState", "security": [],
                        "description": "Admite `on` (o \"t\"), `bri` (0–255), `v` (devolver el estado) y `seg` con `on`, `col`, `fx`, `sx`.",
                        "requestBody": ["content": ["application/json": ["schema": ["type": "object"],
                                                                         "example": ["on": true, "bri": 128, "seg": [["col": [[0, 120, 255]], "fx": 0]], "v": true]]]],
                        "responses": ["200": json(["type": "object"])],
                    ],
                ],
                "/json/info": [
                    "get": ["tags": ["WLED"], "summary": "Información WLED", "operationId": "wledInfo", "security": [],
                            "responses": ["200": json(["type": "object"])]],
                ],
                "/json/eff": [
                    "get": ["tags": ["WLED"], "summary": "Nombres de efectos WLED", "operationId": "wledEffects", "security": [],
                            "responses": ["200": json(["type": "array", "items": ["type": "string"]])]],
                ],
                "/json/pal": [
                    "get": ["tags": ["WLED"], "summary": "Paletas WLED (solo «Default»)", "operationId": "wledPalettes", "security": [],
                            "responses": ["200": json(["type": "array", "items": ["type": "string"]])]],
                ],
                "/json/si": [
                    "get": ["tags": ["WLED"], "summary": "state + info", "operationId": "wledStateInfo", "security": [],
                            "responses": ["200": json(["type": "object"])]],
                ],
                "/win": [
                    "get": [
                        "tags": ["WLED"], "summary": "API HTTP antigua de WLED", "operationId": "wledLegacy", "security": [],
                        "description": "Parámetros tras `&`: `/win&T=1&A=128&R=255&G=0&B=0&FX=3&SX=128`. T: 0 apagar, 1 encender, 2 alternar; A: brillo 0–255.",
                        "parameters": [
                            ["name": "T", "in": "query", "schema": ["type": "integer", "enum": [0, 1, 2]]],
                            ["name": "A", "in": "query", "schema": ["type": "integer", "minimum": 0, "maximum": 255]],
                            ["name": "R", "in": "query", "schema": ["type": "integer"]],
                            ["name": "G", "in": "query", "schema": ["type": "integer"]],
                            ["name": "B", "in": "query", "schema": ["type": "integer"]],
                            ["name": "FX", "in": "query", "schema": ["type": "integer"]],
                            ["name": "SX", "in": "query", "schema": ["type": "integer"]],
                        ],
                        "responses": ["200": ["description": "XML", "content": ["text/xml": ["schema": ["type": "string"]]]]],
                    ],
                ],
            ],
        ]
    }

    /// Real-time frames over UDP. OpenAPI can't describe UDP, so it travels as an extension
    /// that the docs page renders as its own section.
    static func ddp(port: Int, apiPort: Int) -> [String: Any] {
        [
            "title": "Tiempo real (DDP)",
            "summary": "Manda fotogramas a la tira por UDP con el protocolo DDP (el mismo que WLED). Pensado para animaciones desde otro programa: un paquete por fotograma, sin HTTP.",
            "transport": "UDP, puerto \(port) (Ajustes → API → Tiempo real). Sin token. Misma política de red que la API: desde Docker, host.docker.internal.",
            "header": [
                ["bytes": "0", "field": "flags", "value": "0x41 / 0x40",
                 "description": "Bits 7-6 = 01 (versión 1). 0x01 = push: pinta el fotograma; ponlo en el último paquete. 0x10 = hay timecode (la cabecera pasa a 14 bytes y se ignora). 0x02 = consulta: no se responde."],
                ["bytes": "1", "field": "secuencia", "value": "0–15",
                 "description": "4 bits bajos. Informativo; no se reordena."],
                ["bytes": "2", "field": "tipo", "value": "0x0B",
                 "description": "RGB de 8 bits. También se aceptan 0x01 y 0x00 como RGB."],
                ["bytes": "3", "field": "destino", "value": "1",
                 "description": "Salida por defecto. 255 (todas) también vale; otros se ignoran."],
                ["bytes": "4–7", "field": "desplazamiento", "value": "0",
                 "description": "Bytes desde el primer LED, 32 bits big-endian. LED k empieza en k × 3."],
                ["bytes": "8–9", "field": "longitud", "value": "n × 3",
                 "description": "Bytes de datos de este paquete, 16 bits big-endian. Hasta 1440 por paquete (480 LEDs)."],
                ["bytes": "10…", "field": "datos", "value": "R,G,B…",
                 "description": "Tres bytes por LED en el orden de la tira: el LED 0 es el inicio de la disposición (esquina y sentido de Disposición)."],
            ],
            "rules": [
                "Un fotograma puede ir en varios paquetes; se pinta al llegar el que lleva push. Las partes no enviadas conservan lo anterior.",
                "Con el primer fotograma empieza el tiempo real: manda sobre la pantalla, los efectos, el color fijo y los avisos, y enciende la tira aunque esté apagada.",
                "Se aplican el brillo de Ledly, la temperatura, las ganancias de color y el límite de consumo. No se aplican gamma ni saturación.",
                "Se muestra tal cual llega, sin suavizado: la animación la hace quien manda.",
                "Si sobran LEDs se ignoran; si faltan, los que no llegan quedan apagados. El número de LEDs está en `leds` de GET /api/state.",
                "Sin fotogramas durante 2,5 s vuelve sola a lo que tenía (también a apagada), sin tocar ningún ajuste.",
                "POST /api/state {\"live\": false} (o POST /json/state {\"live\": false}, como en WLED) suelta el tiempo real al momento; los paquetes que lleguen durante 1 s después se ignoran.",
                "GET /api/state: `live` (true/false) y `liveSource` (dirección de quien manda).",
            ],
            "examples": [
                ["title": "PHP (un paquete por fotograma)", "code": """
                $sock = socket_create(AF_INET, SOCK_DGRAM, SOL_UDP);
                $leds = 96;                                    // GET /api/state → leds
                for ($seq = 0; ; $seq++) {
                    $data = '';
                    for ($i = 0; $i < $leds; $i++) {
                        $data .= chr(255) . chr(0) . chr(($i * 8) % 256);   // R, G, B
                    }
                    $header = pack('CCCCNn', 0x41, $seq & 0x0F, 0x0B, 1, 0, strlen($data));
                    socket_sendto($sock, $header . $data, 10 + strlen($data), 0, 'host.docker.internal', \(port));
                    usleep(33333);                             // 30 fps
                }
                """],
                ["title": "PHP (fotograma en varios paquetes)", "code": """
                $chunks = str_split($data, 1440);
                foreach ($chunks as $k => $chunk) {
                    $push = $k === count($chunks) - 1 ? 0x01 : 0;
                    $header = pack('CCCCNn', 0x40 | $push, $seq & 0x0F, 0x0B, 1, $k * 1440, strlen($chunk));
                    socket_sendto($sock, $header . $chunk, 10 + strlen($chunk), 0, 'host.docker.internal', \(port));
                }
                """],
                ["title": "Python", "code": """
                import socket
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                data = bytes([255, 0, 0]) * 96
                header = bytes([0x41, 0, 0x0B, 1]) + (0).to_bytes(4, "big") + len(data).to_bytes(2, "big")
                sock.sendto(header + data, ("localhost", \(port)))
                """],
                ["title": "Soltar el tiempo real", "code": """
                curl -X POST http://localhost:\(apiPort)/api/state -d '{"live": false}'
                """],
            ],
        ]
    }

    /// Self-contained page (no CDN, works offline) that renders `/api/openapi.json`.
    static let html = """
    <!doctype html>
    <html lang="es">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Ledly API</title>
    <style>
    :root { --bg:#121214; --side:#18181A; --card:#1A1A1D; --field:#202023; --line:#2A2A2E; --line2:#3A3A3F;
      --text:#ECECEE; --text2:#A1A1A6; --text3:#8A8A90; --accent:#5C8CFF; --accentText:#7AA2FF; --accentFill:#3566E0;
      --ok:#3CCF7A; --warn:#F5C46B; --danger:#FF7B7B; }
    * { box-sizing: border-box; }
    body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
    a { color:var(--accentText); }
    code, pre, .mono { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size:12.5px; }
    code { background:var(--field); padding:1px 5px; border-radius:4px; }
    .layout { display:flex; min-height:100vh; }
    nav { width:260px; flex:none; background:var(--side); border-right:1px solid var(--line); padding:22px 12px; position:sticky; top:0; height:100vh; overflow:auto; }
    nav .brand { display:flex; gap:10px; align-items:center; font-weight:600; font-size:16px; padding:0 8px 18px; }
    nav .logo { width:28px; height:28px; border-radius:7px; background:var(--accentFill); display:grid; place-items:center; color:#fff; font-size:15px; }
    nav h4 { font-size:11px; letter-spacing:.6px; text-transform:uppercase; color:var(--text3); margin:16px 10px 6px; }
    nav a { display:flex; gap:8px; align-items:center; padding:5px 10px; border-radius:8px; color:var(--text2); text-decoration:none; font-size:13px; }
    nav a:hover { background:var(--field); color:var(--text); }
    main { flex:1; min-width:0; padding:36px 40px 80px; max-width:980px; }
    h1 { font-size:24px; margin:0 0 4px; } h2 { font-size:18px; margin:36px 0 12px; }
    .muted { color:var(--text2); }
    .card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:18px 20px; margin:12px 0; }
    .intro li { margin:4px 0; }
    .op { scroll-margin-top:16px; }
    .op-head { display:flex; gap:10px; align-items:center; cursor:pointer; flex-wrap:wrap; }
    .method { font-weight:700; font-size:11px; padding:3px 8px; border-radius:6px; min-width:54px; text-align:center; }
    .GET { background:#1E3A2A; color:var(--ok); } .UDP { background:#33264A; color:#C7A2FF; } .POST { background:#22304F; color:var(--accentText); }
    .PUT, .PATCH { background:#3A2F18; color:var(--warn); } .DELETE { background:#3A1E20; color:var(--danger); }
    .path { font-weight:600; }
    .summary { color:var(--text2); }
    .lock { color:var(--warn); font-size:12px; }
    .op-body { display:none; margin-top:14px; border-top:1px solid var(--line); padding-top:14px; }
    .op.open .op-body { display:block; }
    .label { font-size:11px; letter-spacing:.6px; text-transform:uppercase; color:var(--text3); margin:14px 0 6px; font-weight:600; }
    table { width:100%; border-collapse:collapse; font-size:13px; }
    td, th { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align:top; }
    th { color:var(--text3); font-weight:600; font-size:12px; }
    pre { background:var(--field); border:1px solid var(--line); border-radius:8px; padding:12px; overflow:auto; margin:6px 0; white-space:pre-wrap; word-break:break-word; }
    textarea { width:100%; min-height:110px; background:var(--field); color:var(--text); border:1px solid var(--line2); border-radius:8px; padding:10px; font-family:ui-monospace, Menlo, monospace; font-size:12.5px; }
    input, select { background:var(--field); color:var(--text); border:1px solid var(--line2); border-radius:8px; padding:6px 10px; font:inherit; }
    button { background:var(--accentFill); color:#fff; border:0; border-radius:8px; padding:7px 14px; font:inherit; font-weight:600; cursor:pointer; }
    button.secondary { background:var(--field); color:var(--text); border:1px solid var(--line2); font-weight:400; }
    .row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
    .status { font-size:12px; color:var(--text3); }
    .ok { color:var(--ok); } .err { color:var(--danger); }
    .chips { display:flex; flex-wrap:wrap; gap:6px; }
    .chip { background:var(--field); border:1px solid var(--line); border-radius:999px; padding:2px 10px; font-size:12px; }
    .topbar { display:flex; justify-content:space-between; align-items:flex-start; gap:16px; flex-wrap:wrap; }
    @media (max-width: 760px) { nav { display:none; } main { padding:24px 16px 60px; } }
    </style>
    </head>
    <body>
    <div class="layout">
      <nav id="nav"><div class="brand"><div class="logo">✦</div>Ledly API</div></nav>
      <main>
        <div class="topbar">
          <div><h1 id="title">Ledly API</h1><div class="muted" id="version"></div></div>
          <div class="row"><input id="token" placeholder="Token (si hay)" size="22" autocomplete="off">
            <a href="/api/openapi.json" class="mono">openapi.json</a></div>
        </div>
        <div class="card intro" id="intro"></div>
        <div id="ddp"></div>
        <div id="ops"></div>
      </main>
    </div>
    <script>
    const $ = (s, el = document) => el.querySelector(s);
    const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
    const md = s => esc(s).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g, '<b>$1</b>');
    const tokenInput = $('#token');
    try { tokenInput.value = localStorage.getItem('ledly-token') || ''; } catch (e) {}
    tokenInput.addEventListener('input', () => { try { localStorage.setItem('ledly-token', tokenInput.value); } catch (e) {} });

    function resolve(spec, schema) {
      if (schema && schema.$ref) return resolve(spec, schema.$ref.split('/').slice(1).reduce((o, k) => o[k], spec));
      return schema || {};
    }
    function typeOf(spec, s) {
      s = resolve(spec, s);
      if (s.enum) return s.enum.map(v => '<code>' + esc(v) + '</code>').join(' ');
      if (s.oneOf) return 'texto, lista u objeto';
      if (s.type === 'array') return 'lista de ' + typeOf(spec, s.items);
      let t = s.type || 'objeto';
      if (s.minimum !== undefined || s.maximum !== undefined) t += ' (' + (s.minimum ?? '…') + '–' + (s.maximum ?? '…') + ')';
      return esc(t);
    }
    function propsTable(spec, schema) {
      const s = resolve(spec, schema);
      if (!s.properties) return '';
      let rows = Object.entries(s.properties).map(([k, v]) => {
        const r = resolve(spec, v);
        return `<tr><td class="mono">${esc(k)}</td><td>${typeOf(spec, v)}</td><td class="muted">${md(r.description || '')}</td></tr>`;
      }).join('');
      return (s.description ? `<p class="muted">${md(s.description)}</p>` : '') +
        `<table><tr><th>Campo</th><th>Tipo</th><th>Descripción</th></tr>${rows}</table>`;
    }

    async function load() {
      const spec = await (await fetch('/api/openapi.json')).json();
      document.title = spec.info.title;
      $('#title').textContent = spec.info.title;
      $('#version').textContent = 'Versión ' + spec.info.version + ' · ' + location.origin;
      $('#intro').innerHTML = '<ul>' + spec.info.description.split('\\n').filter(l => l.startsWith('- '))
        .map(l => '<li>' + md(l.slice(2)).replaceAll('&lt;host&gt;', esc(location.host.split(':')[0])) + '</li>').join('') + '</ul>' +
        '<div class="label">Efectos</div><div class="chips">' +
        spec.components.schemas.Effect.properties.id.enum.map(e => `<span class="chip mono">${esc(e)}</span>`).join('') + '</div>';

      const ddp = spec['x-ddp'];
      if (ddp) {
        $('#nav').insertAdjacentHTML('beforeend', '<h4>Tiempo real</h4><a href="#ddp-section"><span class="method UDP" style="min-width:44px;font-size:10px">UDP</span>DDP</a>');
        $('#ddp').innerHTML = `<h2 id="ddp-section">${esc(ddp.title)}</h2><p class="muted">${md(ddp.summary)}</p>
          <div class="card"><div class="label" style="margin-top:0">Transporte</div><p>${md(ddp.transport)}</p>
          <div class="label">Cabecera (10 bytes)</div><table><tr><th>Byte</th><th>Campo</th><th>Valor</th><th>Descripción</th></tr>
          ${ddp.header.map(h => `<tr><td class="mono">${esc(h.bytes)}</td><td>${esc(h.field)}</td><td class="mono">${esc(h.value)}</td><td class="muted">${md(h.description)}</td></tr>`).join('')}</table>
          <div class="label">Comportamiento</div><ul>${ddp.rules.map(r => `<li>${md(r)}</li>`).join('')}</ul>
          ${ddp.examples.map(e => `<div class="label">${esc(e.title)}</div><pre>${esc(e.code)}</pre>`).join('')}</div>`;
      }

      const groups = {};
      for (const [path, methods] of Object.entries(spec.paths))
        for (const [method, op] of Object.entries(methods))
          (groups[op.tags[0]] ||= []).push({ path, method: method.toUpperCase(), op });

      const nav = $('#nav'), ops = $('#ops');
      for (const tag of spec.tags) {
        const list = groups[tag.name]; if (!list) continue;
        nav.insertAdjacentHTML('beforeend', `<h4>${esc(tag.name)}</h4>`);
        ops.insertAdjacentHTML('beforeend', `<h2>${esc(tag.name)}</h2>` + (tag.description ? `<p class="muted">${esc(tag.description)}</p>` : ''));
        for (const { path, method, op } of list) {
          const id = op.operationId;
          const locked = !(op.security && op.security.length === 0) && path.startsWith('/api');
          nav.insertAdjacentHTML('beforeend', `<a href="#${id}"><span class="method ${method}" style="min-width:44px;font-size:10px">${method}</span>${esc(path)}</a>`);
          const body = op.requestBody?.content?.['application/json'];
          const examples = body?.examples ? Object.values(body.examples) : body?.example ? [{ summary: 'Ejemplo', value: body.example }] : [];
          const response = op.responses['200']?.content?.['application/json']?.schema;
          let html = `<div class="card op" id="${id}"><div class="op-head">
            <span class="method ${method}">${method}</span><span class="path mono">${esc(path)}</span>
            <span class="summary">${esc(op.summary)}</span>${locked ? '<span class="lock" title="Pide token si hay uno configurado">🔒</span>' : ''}</div>
            <div class="op-body">`;
          if (op.description) html += `<p class="muted">${md(op.description)}</p>`;
          if (op.parameters) html += '<div class="label">Parámetros</div><table><tr><th>Nombre</th><th>Tipo</th></tr>' +
            op.parameters.map(p => `<tr><td class="mono">${esc(p.name)}</td><td>${typeOf(spec, p.schema)}</td></tr>`).join('') + '</table>';
          if (body) html += '<div class="label">Cuerpo</div>' + propsTable(spec, body.schema);
          if (response && resolve(spec, response).properties) html += '<div class="label">Respuesta</div>' + propsTable(spec, response);
          html += '<div class="label">Probar</div>';
          if (examples.length > 1) html += `<div class="row" style="margin-bottom:6px"><select class="ex">${examples.map((e, i) => `<option value="${i}">${esc(e.summary)}</option>`).join('')}</select></div>`;
          if (method !== 'GET') html += `<textarea class="body">${esc(examples[0] ? JSON.stringify(examples[0].value, null, 2) : '')}</textarea>`;
          const tryPath = path === '/win' ? '/win&T=2' : path;
          html += `<div class="row" style="margin-top:8px"><button class="run">Enviar</button>
            <button class="secondary curl">Copiar curl</button><span class="status"></span></div><pre class="out" hidden></pre></div></div>`;
          ops.insertAdjacentHTML('beforeend', html);
          const card = document.getElementById(id);
          $('.op-head', card).onclick = () => card.classList.toggle('open');
          const sel = $('.ex', card);
          if (sel) sel.onchange = () => $('.body', card).value = JSON.stringify(examples[sel.value].value, null, 2);
          const headers = () => {
            const h = { 'Content-Type': 'application/json' };
            if (tokenInput.value && path.startsWith('/api')) h.Authorization = 'Bearer ' + tokenInput.value;
            return h;
          };
          $('.run', card).onclick = async () => {
            const out = $('.out', card), status = $('.status', card);
            const started = performance.now();
            try {
              const res = await fetch(tryPath, { method, headers: headers(), body: method === 'GET' ? undefined : $('.body', card).value });
              const text = await res.text();
              let shown = text; try { shown = JSON.stringify(JSON.parse(text), null, 2); } catch (e) {}
              status.innerHTML = `<span class="${res.ok ? 'ok' : 'err'}">${res.status}</span> · ${Math.round(performance.now() - started)} ms`;
              out.textContent = shown; out.hidden = false;
            } catch (e) { status.innerHTML = '<span class="err">' + esc(e.message) + '</span>'; }
          };
          $('.curl', card).onclick = () => {
            const h = headers(); let cmd = `curl${method === 'GET' ? '' : ' -X ' + method}`;
            if (h.Authorization) cmd += ` -H 'Authorization: ${h.Authorization}'`;
            if (method !== 'GET') cmd += ` -d '${$('.body', card).value.replace(/\\s*\\n\\s*/g, ' ')}'`;
            cmd += ` '${location.origin}${tryPath}'`;
            navigator.clipboard?.writeText(cmd);
            $('.status', card).textContent = 'curl copiado';
          };
        }
      }
      // Sections are built after loading, so jump to the link's target now.
      const target = location.hash && document.querySelector(location.hash);
      if (target) { target.classList.add('open'); target.scrollIntoView(); }
    }
    load().catch(e => { $('#intro').innerHTML = '<span class="err">No se pudo cargar openapi.json: ' + esc(e.message) + '</span>'; });
    </script>
    </body>
    </html>
    """
}
