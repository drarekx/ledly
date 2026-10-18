# Roadmap

Orden de trabajo. Marcar `[x]` al terminar y anotar lo que haya costado en CLAUDE.md.

## Fase 1 — Base sólida

- [x] **Firma estable**: firmar siempre con el mismo certificado para que macOS no vuelva a pedir Grabación de pantalla en cada compilación.
- [x] **1 000 000 baudios**: doble de margen para tiras largas (medido: 150 LEDs a 83 fps, 300 a 46 fps, sin pérdidas). Firmware v2; la app detecta la versión del Nano y usa la velocidad que toque.
- [x] **Anti-parpadeo**: histéresis de 1 paso en la salida de 8 bits (simulado con ruido de captura: 129 → 0 cambios de nivel) y suavizado tipo muelle (por defecto). Dithering temporal descartado: a 50 fps alternar niveles es justo el parpadeo que se quiere quitar.
- [x] **Limitador de consumo**: estimación WS2812B (20 mA por canal + 1 mA por LED), límite configurable en Dispositivo (1000 mA por defecto) y en la API (`power`). Probado en la tira: blanco a tope recortado a ~1000 mA.
- [x] **Ahorro**: fotogramas idénticos solo se repiten 2 veces por segundo; colores en vivo en un objeto aparte (`LEDPreview`) que solo se actualiza si hay vista previa o clientes WebSocket; en Efectos solo se anima la tarjeta bajo el ratón y la activa. Medido con un efecto: ventana abierta 14–18 % → 6 % de CPU; cerrada 0,9 %.

## Fase 2 — Funciones grandes

- [x] **Efectos con música**: audio del sistema por ScreenCaptureKit (mismo permiso) + FFT de 1024 muestras con Accelerate, 16 bandas con ganancia automática, graves y golpes. Efectos: Pulso musical, Ecualizador, Ondas musicales, Vúmetro. La captura de audio solo corre con un efecto de música activo (CPU ~1,7 %). `audio` en `/api/state`.
- [x] **Ecualizador configurable**: disposición (desde abajo, desde arriba, estéreo, anillo, cuatro espejos) × estilo (espectro, barras, nivel, destellos) × colores (arcoíris, fijo, calor, semáforo, ciclo) = 100 combinaciones, más 8 combinaciones rápidas y sensibilidad. Análisis por canal para el estéreo. En la API: `"equalizer": {…}`.
- [ ] **Stream Deck y Atajos**: acciones de Atajos de macOS (App Intents) y botones para el Stream Deck.
- [x] **Tiempo real por DDP** (UDP 4048): fotogramas en uno o varios paquetes con push, prioridad sobre todo salvo apagado, vuelta sola a los 2,5 s, `{"live": false}` para soltar al momento (ignora 1 s de paquetes retrasados), `live`/`liveSource` en `/api/state`, compatible con el `live` de WLED. Probado desde la red y desde un contenedor (Colima, `host.docker.internal`).
- [ ] **Más protocolos de red**: WLED UDP (DRGB/DNRGB, puerto 21324), E1.31/Art-Net, servidor Hyperion. Para LedFx, xLights, HyperHDR en la tele.

## Fase 3 — Pulido

- [ ] **Capturar una ventana o app** en vez de toda la pantalla.
- [ ] **Asistentes**: disposición (LED a LED) y balance de blancos.
- [ ] **Vista de la captura** con las zonas de cada LED encima.
- [ ] **HDR**: captura HDR y mapeo de tonos para la tira.
- [x] **Firmware desactualizado**: avisar y ofrecer reinstalar cuando el Nano lleva una versión anterior.

## Fase 4 — Preparar Windows (futuro)

Objetivo: que un port a Windows sea escribir unas pocas piezas por plataforma, no rehacer la app.

- [ ] **Núcleo sin Apple** (`LedlyCore`, paquete Swift aparte): efectos, ecualizador, suavizado, anti-parpadeo, consumo, disposición, colores, protocolo Adalight con confirmación, instalador STK500, lógica de API/WLED/DDP, traducciones. La app de Mac lo usa igual que ahora.
- [ ] **Interfaces por plataforma** para lo que cambia: captura de pantalla, audio del sistema, puerto serie y lista de puertos, sockets HTTP/WebSocket/UDP, ajustes, inicio de sesión, actualizador.
- [ ] **Interfaz web** servida por la propia API (como `/api/docs`): la misma en Mac y Windows; la app nativa queda en icono de barra/bandeja + ventana que la muestra.
- [ ] **Port a Windows**: Swift para Windows con DXGI Desktop Duplication (pantalla), WASAPI loopback (audio), puertos COM de Win32, icono en la bandeja y su propio instalador/actualizador.

Mientras tanto, en Windows la tira funciona con HyperHDR o Prismatik (Adalight a 1 000 000 baudios), sin la confirmación por fotograma.

## Descartado

- **Escenas y horarios** (guardar combinaciones y aplicarlas por hora): no se quiere.
