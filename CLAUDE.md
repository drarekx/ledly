# Ledly

App de macOS (barra de menú) que controla una tira WS2812B conectada a un Arduino Nano con los colores del borde de la pantalla (ambilight), efectos o un color fijo, y ofrece una API HTTP/WebSocket compatible con WLED. Swift + AppKit/SwiftUI, sin dependencias externas en el código. Misma base y estilo que Wallpy (`../wallpapers`). Repo: https://github.com/drarekx/ledly (público).

Réplica limpia (clean-room) de HyperHDR analizada con REA: `docs/hyperhdr-notes.md` describe su comportamiento (protocolo Adalight/AWA, mapeo de zonas, suavizado, efectos, valores por defecto). No se copia código ni recursos de HyperHDR.

## Compilar y ejecutar

```sh
swift build                      # debug, comprobación rápida
./build-app.sh                   # release universal → build/Ledly.app + build/Ledly.zip (incluye firmware/hex)
VERSION=1.1.0 ./build-app.sh
.build/debug/Ledly --read-flash /dev/cu.usbserial-XXXX out.hex   # vuelca el firmware del Nano (solo lee)
.build/debug/Ledly --flash /dev/cu.usbserial-XXXX 6              # instala el firmware del pin D6
```

- Requisitos: macOS 14+, Xcode 16+. Tools 5.10 (modo Swift 5).
- No hay tests. Verificar compilando y con la API (`curl localhost:8765/api/state`), que da estado del dispositivo, fps y captura.
- Solo una copia abierta a la vez: el puerto serie se abre en exclusiva. HyperHDR también puede quedarse el puerto.

## Publicar una versión

```sh
git tag v1.1.0 && git push origin v1.1.0
```

`.github/workflows/release.yml` (macos-15) compila con `VERSION` = tag y crea el release con `Ledly.zip` y `Ledly.zip.sha256`. Las apps instaladas se actualizan solas (`Updater.swift`, `releases/latest`). Instalador: `install.sh` (`curl … | bash`); no instala dependencias. En CI no hay certificado: la app sale con firma ad-hoc. `.github/workflows/build.yml` compila arm64 + x86_64 y comprueba las traducciones en cada push y PR.

## Firmware (`firmware/`)

- `Ledly/Ledly.ino` (v2): Adalight (`Ada` + cuenta−1 en big-endian + `hi^lo^0x55` + RGB) a 1 000 000 baudios, FastLED. Extensiones: al arrancar imprime `Ada Ledly <ver> pin <n> max 400 baud <b>`, y tras cada `show()` responde `k`; el host espera ese `k` antes de mandar el siguiente fotograma (si no, los bytes que llegan con interrupciones cortadas se pierden). Se apaga tras 15 s sin datos.
- `build.sh` compila un `.hex` por pin (D2–D13) en `firmware/hex/`. Los `.hex` se versionan; compilar la app no necesita toolchain AVR.
- Toolchain: `arduino-cli` + `arduino:avr` + **FastLED 3.7.8** (3.10 no compila con avr-gcc 14). El avr-gcc y ctags de Arduino son x86_64: sin Rosetta se usa `avr-gcc@14` del tap `osx-cross/avr` y `build.sh` salta ctags.
- La app prueba al conectar la velocidad que funcionó la última vez, luego 1 000 000 y 500 000 (v1). Si el Nano lleva una versión anterior a `Firmware.version`, la pestaña Dispositivo ofrece actualizarlo.
- Al subir de versión el firmware: cambiar `LEDLY_VERSION` en el sketch y `Firmware.version` en `Flasher.swift`, y ejecutar `build.sh`.
- La macro del pin se llama `LED_PIN`: `DATA_PIN` choca con un parámetro de plantilla de FastLED.

## Estructura (`Sources/Ledly/`)

| Archivo | Qué hace |
|---|---|
| `main.swift`, `AppDelegate.swift` | Arranque, app accesoria, menú de barra (encendido, modos, efectos, brillo), menú Edición oculto, `--flash`/`--read-flash` |
| `LEDEngine.swift` | `LEDEngine` (estado publicado, puertos, instalar firmware, avisos temporales) y `OutputLoop` (bucle a 50 Hz en su cola: fuente → corrección → suavizado → envío) |
| `Smoothing.swift` | `Smoother` (exponencial o muelle, histéresis anti-parpadeo al pasar a 8 bits) y `PowerModel` (consumo estimado y limitador) |
| `LEDDevice.swift` | Conexión Adalight: reset por DTR, saludo, espera del `k` |
| `SerialPort.swift` | Puerto POSIX 8N1, baudios arbitrarios (`IOSSIOSPEED`), lista de puertos USB por IOKit |
| `Flasher.swift` | STK500 v1 (Optiboot 115200 / ATmegaBOOT 57600): firma, copia de seguridad, escritura y verificación; Intel HEX |
| `ScreenGrabber.swift` | ScreenCaptureKit a 256 px de ancho, media por zona (media / lineal / dominante), detector de bordes negros |
| `LEDLayout.swift` | Disposición (LEDs por lado, esquina, sentido, desplazamiento, hueco del pie) → zonas ordenadas |
| `LEDColor.swift` | `RGB`, HSV, `ColorAdjustments` (brillo, gamma, saturación, temperatura, luz mínima, ganancias) |
| `AudioAnalyzer.swift` | Audio del sistema con ScreenCaptureKit (sin salida de vídeo), FFT con Accelerate → `AudioLevels` (16 bandas, nivel, graves, golpe). `AudioLevels.demo` alimenta las vistas previas |
| `Equalizer.swift` | Ecualizador configurable (`EqualizerOptions`: disposición × estilo × colores + sensibilidad, combinaciones rápidas) y `EqualizerRenderer`, usado por `EffectKind.musicSpectrum` |
| `Effects.swift` | `EffectKind` y `EffectRenderer` (efectos procedurales sobre la posición de cada LED) |
| `DDPReceiver.swift` | DDP por UDP (4048): junta paquetes y entrega el fotograma con push a `LEDEngine.receiveLive`. Lo arranca `APIServer` con su misma política de red |
| `APIDocs.swift` | Especificación OpenAPI 3.0 (`/api/openapi.json`) y página HTML autónoma que la pinta y prueba (`/api/docs`, también `/`). Al tocar la API, actualizar aquí |
| `APIServer.swift` | HTTP/1.1 + WebSocket sobre `Network.framework`; API propia y subconjunto WLED; Bonjour `_wled._tcp` |
| `Settings.swift` | `UserDefaults` (`com.mrdrarek.ledly`) y login item |
| `MainView.swift`, `Panes.swift` | Ventana: Inicio, Efectos, Disposición, Dispositivo, Imagen, API, Ajustes; `StripPreview` |
| `Migration.swift` | Copia una vez los ajustes del identificador antiguo (`com.egluu.ledly`) |
| `Theme.swift`, `Localization.swift`, `Updater.swift` | Iguales que en Wallpy (estilo, idiomas, autoactualización desde `drarekx/ledly`) |

Copias del firmware anterior: `~/Library/Application Support/Ledly/Backups/`.

## Convenciones

- Código, comentarios y commits en inglés. Interfaz en castellano, inglés y catalán.
- **Todo texto visible pasa por `tr("…")`**; la clave es el castellano y va en las tablas `en` y `ca` con los mismos `%@`/`%d`. Los nombres de efectos son claves (`EffectKind.titleKey`); para WLED se envían en inglés (`trEnglish`).
- Estilo: `Theme` y sus componentes (`LedlyButtonStyle`, `SegmentedControl`, `SwitchRow`, `ledlyCard`…).
- El estado de la UI es `@MainActor`; el bucle de salida, la captura y el puerto serie viven en sus colas. La API aplica cambios sobre `Settings` en el hilo principal.
- La API y los ajustes guardados usan los `rawValue` de `LightMode`/`EffectKind`: no renombrarlos.

## Cosas que ya costaron (no repetir)

- **Prioridades del bucle de salida** (`OutputLoop.targetColors`): patrones de prueba > tiempo real (DDP, enciende aunque esté apagada) > apagado > efecto de arranque > aviso temporal (`duration`) > modo normal. El tiempo real no toca ajustes: al acabar se vuelve solo a lo que había. Mientras dura, la captura de pantalla y la de audio se paran.

- **A 1 Mbaud cada byte llega cada 160 ciclos** y la interrupción de HardwareSerial + `read()` cuesta más: con más de ~150 LEDs se perdía medio fotograma. Los datos de color se leen sondeando `UDR0` con la interrupción RX apagada (`readColors`). Nada de divisiones en ese camino. Medido: 300 LEDs a 46 fps sin pérdidas.
- **Nada que cambie a ritmo de fotograma en `LEDEngine`**: cada `@Published` suyo redibuja todos los paneles que lo observan (con la ventana abierta llegó a 18 % de CPU). Colores y consumo van en `LEDEngine.shared.preview` (`LEDPreview`), que solo observan `LiveStripPreview` y la tarjeta de consumo; `/api/leds` lee del bucle con `currentColors()`.
- El identificador es `com.mrdrarek.ledly` (app personal, no de egluu). Cambiarlo pierde el permiso de Grabación de pantalla y obliga a migrar los ajustes (`Migration.swift`).
- **Permiso de pantalla «activado» pero denegado**: macOS guarda con el permiso la firma exacta que tenía la app. Lo concedido con firma ad-hoc queda atado a ese `cdhash` y no vale tras cambiar de firma. Arreglo: `tccutil reset ScreenCapture com.mrdrarek.ledly`, reabrir y volver a concederlo. Comprobar con `sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "select hex(csreq) from access where client='com.mrdrarek.ledly'"` + `csreq -r - -t`.
- `build-app.sh` firma con el primer certificado «Apple Development» (o `SIGN_IDENTITY`) para que el permiso de Grabación de pantalla sobreviva a las recompilaciones; sin certificado (CI) firma ad-hoc.

- **Reabrir el puerto enseguida no resetea el Nano** (el condensador de DTR no se recarga) y no llega el saludo: `LEDDevice.connect` pulsa DTR a mano.
- **NSNumber de JSON y `is Bool`**: `0` y `1` pasan por Bool. Comprobar `CFBooleanGetTypeID()` (ver `APIServer.number`).
- Sin menú principal no funciona ⌘V en campos de texto (app accesoria).
- `NSHostingController` encoge la ventana: `sizingOptions = []` y `setContentSize` después.
