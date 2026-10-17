# Ledly

Ambilight para macOS: una tira de LEDs detrás del monitor que sigue los colores del borde de la pantalla, hace efectos (también con la música que suena) y se controla por API. Vive en la barra de menú y funciona con un **Arduino Nano** y una tira **WS2812B**. Réplica limpia de [HyperHDR](https://github.com/awawa-dev/HyperHDR).

## Instalar

Abre Terminal y pega:

```sh
curl -fsSL https://raw.githubusercontent.com/drarekx/ledly/main/install.sh | bash
```

El instalador descarga la última versión, la copia en `/Applications` y la abre. No hace falta nada más: ni Arduino IDE, ni drivers, ni Homebrew. El firmware del Nano va dentro de la app.

Ledly se actualiza sola: busca versiones nuevas al arrancar y una vez al día (o desde el menú → **Buscar actualizaciones…**), comprueba la descarga con su SHA-256 y se reinicia ya actualizada. Se puede desactivar en Ajustes. Volver a ejecutar el comando de instalación también actualiza.

**Instalación manual:** descarga `Ledly.zip` de [Releases](https://github.com/drarekx/ledly/releases/latest), descomprímelo y mueve `Ledly.app` a Aplicaciones. La app no está notarizada por Apple, así que la primera vez ábrela con clic derecho → **Abrir** (o Ajustes del Sistema → Privacidad y seguridad → **Abrir igualmente**).

Requisitos: macOS 14 (Sonoma) o posterior, Apple Silicon o Intel. Un Arduino Nano (vale cualquier clon con CH340, FTDI o CP210x) y una tira WS2812B.

## Primeros pasos

1. **Monta la tira** detrás del monitor y conéctala al Nano:
   - Datos de la tira (DIN) a un pin digital del Nano (D6 es lo habitual), con una resistencia de 330 Ω si puedes.
   - GND de la tira con GND del Nano.
   - Alimenta la tira con una fuente de 5 V propia. El USB del Mac solo da para unos pocos LEDs a poco brillo.
2. **Conecta el Nano por USB.** Ledly lo detecta solo.
3. **Instala el firmware:** Ledly → **Dispositivo** → elige el pin → **Instalar firmware**. Tarda unos segundos y antes guarda una copia del programa que tuviera el Nano. Solo hace falta una vez (y cuando la app avise de que hay una versión nueva).
4. **Di cómo está colocada la tira:** **Disposición** → LEDs de cada lado, esquina del primer LED y sentido, mirando la pantalla de frente. **Comprobar → Dirección** enciende el primer LED en verde y el último en rojo para que veas si cuadra.
5. **Da permiso de Grabación de pantalla** cuando macOS lo pida (o en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla → Ledly). Si ya estaba activado y no lee la pantalla, sal de Ledly y vuelve a abrirla.
6. **Pon el límite de consumo** de tu fuente en **Dispositivo → Consumo** (1000 mA por defecto) para no forzarla.

## Qué hace

- **Pantalla (ambilight)**: color de cada zona del borde (media, lineal o dominante), ignora las franjas negras de las películas, suavizado (exponencial o tipo muelle), anti-parpadeo en escenas oscuras, gamma, saturación, temperatura, luz mínima y ganancia por canal.
- **Efectos**: remolinos y ondas arcoíris, respiración, vela, fuego, coche fantástico, policía, estroboscopio, chispas, manchas de color, olas, plasma, serpiente, barrido, Navidad, reloj, aurora y meteoro, con velocidad y color.
- **Música**: pulso, ondas, vúmetro y un **ecualizador** con 100 combinaciones (disposición × estilo × colores, incluido estéreo) y combinaciones rápidas. Usa el audio del Mac, sin instalar nada.
- **Color fijo** con muestras rápidas.
- **Arduino Nano**: detecta el puerto, instala y actualiza el firmware, reconecta solo. Hasta 400 LEDs (300 LEDs a ~46 fps).
- **Limitador de consumo**: baja el brillo si la tira pasaría del límite de tu fuente.
- **API** HTTP + WebSocket, **tiempo real por DDP** (UDP) y compatibilidad con **WLED** (Home Assistant y las apps de WLED la encuentran en la red).
- Apagado al dormir el Mac, abrir al iniciar sesión, menú de barra con modos, efectos y brillo.
- **Idiomas**: castellano, inglés y catalán (Ajustes → Idioma; por defecto, el del sistema).

## API

Por defecto en el puerto `8765` (Ajustes → API). La documentación completa, con un botón para probar cada ruta, está en la propia app: **http://localhost:8765/api/docs**. La especificación OpenAPI 3.0 está en `/api/openapi.json`. Con token, las rutas `/api` piden `Authorization: Bearer <token>` (o `?token=`).

| Ruta | Qué hace |
|---|---|
| `GET /api/state` | Estado: encendido, modo, efecto, color, brillo, LEDs, fps, dispositivo, captura, consumo, audio, tiempo real |
| `POST /api/state` | Cambia el estado (ver abajo) |
| `GET /api/effects` | Lista de efectos (`id`, nombre, si usa color) |
| `GET /api/leds` | Colores que se están enviando ahora |
| `GET /api/device` · `POST /api/device/reconnect` | Puerto, pin, firmware y estado de la conexión |
| `GET /api/layout` | Disposición de la tira |
| `GET /api/docs` · `GET /api/openapi.json` | Documentación (HTML) y especificación OpenAPI; nunca piden token |
| `WS /api/ws` | Estado en vivo; manda `{"subscribe":"leds"}` para recibir los colores (~15 fps). Acepta los mismos cuerpos que `POST /api/state` |

Cuerpo de `POST /api/state` (todo opcional):

```json
{
  "on": true,
  "toggle": false,
  "mode": "screen | effect | color",
  "effect": "fire",
  "speed": 1.5,
  "equalizer": { "preset": "classic", "layout": "stereo", "style": "bars", "colors": "heat", "sensitivity": 1.2 },
  "color": "#FF2D95",
  "brightness": 60,
  "duration": 3,
  "clear": false,
  "live": false
}
```

- `color` acepta `"#RRGGBB"`, `[r,g,b]` o `{"r":…,"g":…,"b":…}`. Mandar solo un color pasa a modo color; solo un efecto, a modo efecto.
- `equalizer` cambia el ecualizador y lo muestra. `preset`: `classic`, `aurora`, `stereo`, `fire`, `rain`, `halo`, `club`, `mono`; los demás campos retocan la combinación.
- `duration` (segundos) muestra el color o efecto un rato y luego vuelve a lo que había (avisos). `clear` lo corta antes.
- `live: false` suelta el tiempo real (DDP) al momento.

```sh
curl -X POST localhost:8765/api/state -d '{"effect":"strobe","color":"#FF0000","duration":3}'
```

### Tiempo real (DDP)

UDP en el puerto **4048** (Ajustes → API), sin token, con la misma política de red que la API (desde Docker: `host.docker.internal`). Detalles y ejemplos en PHP y Python en **http://localhost:8765/api/docs#ddp-section**.

- Cabecera de 10 bytes (14 con timecode): flags (`0x40` = versión 1, `| 0x01` push en el último paquete), secuencia, tipo `0x0B` (RGB 8 bits), destino `1`, desplazamiento en bytes (32 bits, big-endian), longitud (16 bits). Luego R,G,B por LED en el orden de la tira: el LED 0 es el inicio de la disposición.
- Un fotograma puede ir en varios paquetes (hasta 1440 bytes de datos cada uno); se pinta al llegar el que lleva push.
- Mientras llegan, mandan sobre la pantalla, los efectos, el color y los avisos, y encienden la tira aunque esté apagada (al terminar vuelve a apagarse). Se aplican brillo, temperatura, ganancias y límite de consumo; gamma y saturación no.
- Sin fotogramas durante 2,5 s vuelve sola a lo que tenía, sin tocar los ajustes. `POST /api/state {"live": false}` (o `/json/state {"live": false}`, como en WLED) suelta al momento e ignora durante 1 s los paquetes que lleguen con retraso.
- `/api/state` da `live` (true/false) y `liveSource` (quién manda).

```python
header = bytes([0x41, seq & 15, 0x0B, 1]) + (0).to_bytes(4, "big") + len(data).to_bytes(2, "big")
sock.sendto(header + data, ("host.docker.internal", 4048))
```

### WLED

`GET /json`, `/json/state`, `/json/info`, `/json/eff`, `/json/pal`, `POST /json/state`, `/win&…` y el WebSocket `/ws`. El efecto 0 es «Solid» (color fijo), luego los de Ledly y el último «Ambilight» (pantalla). Con «Anunciar como WLED» se publica `_wled._tcp` por Bonjour para que Home Assistant la descubra.

## Problemas frecuentes

- **No lee la pantalla aunque el permiso está activado**: sal de Ledly y vuelve a abrirla. Si sigue igual, quita Ledly de la lista de Grabación de pantalla, ábrela y concédelo de nuevo (`tccutil reset ScreenCapture com.egluu.ledly` lo borra desde Terminal).
- **No encuentra el Arduino**: prueba otro cable USB (algunos solo cargan) y cierra otras apps que usen el puerto (Arduino IDE, HyperHDR, Prismatik…).
- **Falla al instalar el firmware**: algunos Nano viejos necesitan pulsar el botón de reset justo al empezar la instalación.
- **Colores en el lado equivocado**: Disposición → cambia la esquina del primer LED o el sentido, y comprueba con **Dirección**.
- **La tira parpadea o se reinicia con mucho brillo**: la fuente no da para tanto. Baja el límite de consumo o usa una fuente más grande.

## Dónde guarda las cosas

- Ajustes: `defaults read com.egluu.ledly`
- Copias del firmware anterior del Nano: `~/Library/Application Support/Ledly/Backups/`

## Desinstalar

Sal de Ledly (menú → **Salir de Ledly**), borra `Ledly.app` de Aplicaciones y, si quieres quitar también los ajustes:

```sh
defaults delete com.egluu.ledly
rm -rf ~/Library/Application\ Support/Ledly
```

## Desarrollo

Swift + AppKit/SwiftUI sin dependencias. `swift build` para compilar y `./build-app.sh` para crear `build/Ledly.app`. El firmware está en `firmware/` (ver `firmware/build.sh`). Más detalles en [CLAUDE.md](CLAUDE.md) y en [ROADMAP.md](ROADMAP.md).
