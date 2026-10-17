# HyperHDR 22 (macOS arm64): clean-room behavioral spec for a Swift menubar Adalight replica

Target: `/Applications/hyperhdr.app/Contents/MacOS/hyperhdr`, Mach-O arm64, sha256 `0dd3ff16744d15ecc5125ee9ad4ef6a235d2c74ff3c40bd33f58777c21caec53`. The build string is `v22.0.0.0`.
Method: static analysis only. Nothing was executed. Tools used:
- REA (Hopper provider) for symbols and pseudocode. Citations look like `ev_xxxxxxxx`.
- `strings` over the binary. Citations look like `STR:<line>` in a `strings` dump (not kept).
- The binary's embedded Qt resources, which are zstd-compressed. The JSON schemas, web UI JS and English translations were decompressed during the analysis (not kept). Citations look like `RES:zs_<offset>`.

This document describes behavior in my own words. No source code is reproduced.

Labels: **[O]** = observed directly in the artifact. **[I]** = inferred from observed evidence. **[U]** = unknown or not verified.

## REA evidence index
| ID | What |
|---|---|
| ev_e264354b… | `DriverSerialAdalight` procedure list (CreateHeader, writeFiniteColors, writeInfiniteColors, whiteChannelExtension) |
| ev_3412e440… / ev_51d8d0a1… | `DriverSerialAdalight::CreateHeader` pseudocode / assembly |
| ev_9730599a… | `DriverSerialAdalight::writeFiniteColors` pseudocode (frame + Fletcher checksums) |
| ev_501ad269… | `DriverSerialAdalight::whiteChannelExtension` |
| ev_e28d046e… | `ProviderSerial` / `EspTools` procedure list |
| ev_4e71df54… | `ProviderSerial::tryOpen` |
| ev_a5d3370f… | `EspTools::initializeEsp` (DTR/RTS reset + AWA handshake) |
| ev_90deae94… | `ProviderSerial::waitForExitStats` |
| ev_bce857c8… | `ProviderSerial::close` / `powerOff` |
| ev_3c799554… | interpolators, InfiniteProcessing, BlackBorderDetector, macOsGrabber procedure list |
| ev_535728ad… | Exponential/Stepper interpolator, user gamma, brightness/saturation, backlight, temperature, scale output, black border detector |
| ev_2f07ee40… / ev_bd729493… | `ImageColorAveraging` (LED area averaging) list / pseudocode |
| ev_7a742c3b… | `macOsGrabber::grabFrame` + blocks + `decodeFrame` |
| ev_4a0417f2… / ev_2a13b2f5… | `Animation_*` effect classes list / constructor and Init pseudocode |

---

## 1. Serial LED protocol (Adalight / AWA "HyperSerial")

### 1.1 Driver settings (schema `RES:zs_00278f87`) [O]
| key | default | notes |
|---|---|---|
| output | `"auto"` | auto-discovers the serial port |
| awa_mode | **true** | the HyperSerial "AWA" protocol with an integrity check |
| rate | **2000000** baud | the AWA default. Classic Adalight sketches on a Nano use 115200, 230400, 460800 or 500000 [I] |
| espHandshake | false | only applies when awa_mode is on |
| forceSerialDetection | false | only applies when awa_mode is on |
| white_channel_calibration | false | RGBW firmware only. Takes limit 100%, plus R/G/B 255 each |
| delayAfterConnect | **0 ms** | only shown when awa_mode is off |
| lightberry_apa102_mode | false | only applies when awa_mode is off |
| maxRetry | 0 | |

Common device settings (`STR:2073-2100`) [O]:
- `colorOrder` defaults to `"rgb"`. Allowed values: rgb, bgr, rbg, brg, gbr, grb.
- `refreshTime` (Refresh time) defaults to **0 ms**, which means no keepalive re-send.

### 1.2 Header (6 bytes): `CreateHeader` [O] (ev_3412e440, ev_51d8d0a1)
```
byte0 = 'A' (0x41)
byte1 = 'd' (0x64)   classic Adalight          (awa_mode = false)
        'w' (0x77)   AWA, normal 8-bit frames   (awa_mode = true)
        'W' (0x57)   AWA "infinite"/high-precision variant
byte2 = 'a' (0x61)   normally
        'A' (0x41)   AWA + white_channel_calibration + finite ('w') frames
byte3 = high byte of (ledCount - 1)
byte4 = low  byte of (ledCount - 1)
byte5 = byte3 XOR byte4 XOR 0x55
```
- The "minus one" was seen in the assembly as `sub w26,w26,#1` before the big-endian store. **[O]**
- The classic sequence is therefore `41 64 61 hi lo chk`, which is the standard "Ada" header used by every Adalight Arduino sketch.
- Logging prints the header as `Adalight header for {n} {finite|infinite} leds: {c}{c}{c} {d} {d} {d}`. [O STR:26061]
- LightBerry APA102 mode is different. It does not subtract 1, uses 4 bytes per LED with a 0xFF lead byte, and appends an end-frame of max(4, (n+15)/16) bytes. Not needed for WS2812B. [O]

### 1.3 Frame body: `writeFiniteColors` [O] (ev_9730599a)
1. If the LED count differs from the last header, rebuild the header. Log: "Adalight led count has changed … Rebuilding header".
2. Copy the RGB bytes (3 per LED) right after the 6-byte header. They are already in the configured color order.
3. **Classic Adalight ('Ada')**: send header + RGB. There is no trailer.
4. **AWA ('Awa'/'AwA')**:
   - If white calibration is on, append 4 bytes: `limit, red, green, blue` (whiteChannelExtension, ev_501ad269).
   - Then append 3 checksum bytes computed over every byte after the header (RGB data plus any calibration bytes):
     - `f1 = (f1 + b) mod 255`, then `f2 = (f2 + f1) mod 255`. This is Fletcher-16 style.
     - `fx = (fx + (b XOR i)) mod 255`, where `i` is the byte's 0-based index in the payload.
     - Trailer order: **byte A = f1, byte B = f2, byte C = fx**.
     - If `fx == 0x41` ('A'), send 0xAA instead. This stops the trailer being mistaken for a header start.
     - An empty payload gives a trailer of `00 00 00`.
5. If the buffer size no longer matches, the frame is skipped. Log: "buffer's size has changed. Skipping refresh".

Swift pseudocode (my own):
```
func adalightFrame(colors:[RGB]) -> [UInt8] {
  let n = colors.count - 1
  var out:[UInt8] = [0x41, 0x64, 0x61, UInt8(n>>8), UInt8(n&0xFF), 0]
  out[5] = out[3] ^ out[4] ^ 0x55
  for c in colors { out += [c.r, c.g, c.b] }   // after colorOrder permutation
  return out
}
// AWA: change byte1 to 0x77, then append [f1, f2, fx] computed over out[6...].
```

### 1.4 Opening, reset and handshake
- **[O]** (ev_4e71df54) `tryOpen`:
  - sets the port name and baud rate, then opens read-write;
  - if espHandshake is on, calls `EspTools::initializeEsp`;
  - otherwise, after a successful open, waits `delayAfterConnect` ms using a Qt single-shot timer. Logs: "delayAfterConnect for {d} ms - start/finished".
  - The non-ESP path does not set DTR or RTS explicitly. **[O, by absence in the filtered call list]**
- **[I]** On macOS, opening a CH340 port asserts DTR, which auto-resets an Arduino Nano. The bootloader then needs about 1.5–2 s. A replica should either wait about 2000 ms after open, or wait until it reads the sketch's `"Ada\n"` greeting. HyperHDR itself has no "Ada" greeting check; no such string was found (`STR` grep). **[O absence]**
- **[O]** (ev_a5d3370f) ESP/Pico handshake. This is AWA only and not relevant to the Nano.
  - The boards are identified by USB VID/PID: RP2040 VID 0x2E8A, Espressif 0x303A, and others.
  - Reset sequence: toggle DTR/RTS with sleeps of 50 ms, 150 ms and 100 ms.
  - Then write the 8 bytes `41 77 41 2A A2 15 68 79` ("AwA*" + magic) and read the firmware's reply. Log: "DETECTED DEVICE USING HyperSerialEsp8266/…".
- **[O]** (ev_bce857c8, ev_90deae94) On close with the ESP handshake enabled:
  - write `41 77 41 2A A2 35 68 79`;
  - wait about 100 ms for a newline-terminated "goodbye" statistics line;
  - flush and close.
  - powerOff writes black.
- **Keepalive [O]**: `refreshTime` defaults to 0, so the last frame is not re-sent. The log warns that enabling it may limit performance (`STR:~26090`). Smoothing can also drive output: "Forcing smoothing refresh rate", and `continuousOutput` (default false) re-sends even unchanged frames.
  - **[I]** Classic Adalight sketches time out and blank after about 150 s without data unless they are fed. A replica can re-send the last frame every ~1–5 s, or run continuous output.
- Write timeout: frames are dropped and counted when a write times out. Log: "Timeout after {d}ms: {d} frames already dropped". **[O STR]**

### 1.5 Arduino-sketch hints (Q8)
- **[O]** No Arduino sketch is embedded.
- The only references are to HyperSerial firmwares (`HyperSerialEsp8266/ESP32/Pico`), the wiki `https://wiki.hyperhdr.eu/HyperSerial`, and the protocol string "high speeed & data integration check AWA protocol".
- **[I]** For a Nano with WS2812B, use a standard Adalight sketch: header `Ada`, count-1 in big-endian, XOR 0x55 checksum, 115200–500000 baud, and a `"Ada\n"` greeting on boot. The AWA trailer is only understood by HyperSerial firmware, and the Nano (ATmega328P) cannot reach 2 Mbaud reliably with the CH340.

---

## 2. Screen capture on macOS (Q2)
- **[O]** The binary links `ScreenCaptureKit`, `AVFoundation`, `CoreGraphics` and `CoreVideo`. AVFoundation is only used by the USB video grabber `AVFGrabber`.
- **[O]** (ev_7a742c3b) `macOsGrabber::grabFrame` polls rather than streams. Each frame it:
  1. calls `SCShareableContent getShareableContentWithCompletionHandler`, then finds the display matching the selected `displayID`;
  2. reads the display mode's pixel width and point width to get the backing scale;
  3. builds `SCContentFilter(display:, excludingWindows: [])` and an `SCStreamConfiguration` with:
     - width/height = downscaled target;
     - sourceRect = the full display bounds;
     - `captureResolution = 1`, `scalesToFit = false`, `queueDepth = 1`;
  4. calls **`SCScreenshotManager captureImageWithFilter:configuration:completionHandler:`**;
  5. converts the result with `CGImageCreateCopyWithColorSpace` (an sRGB space);
  6. `decodeFrame` takes the CGImage data provider bytes and passes them as BGRA rows to `processSystemFrameBGRA`.
  - If the display is not found, it stops and retries via a 3-second single-shot timer.
  - `SCStream` and `CGDisplayStream` are not used. **[O by call sites; I for completeness]**
- **[O]** System grabber schema (`RES:zs_0026e1c7`):
  - `videoMode` (max width) defaults to **512** (min 196, max 1280);
  - `fps` defaults to **20** (5–120);
  - `hardware` acceleration defaults to true;
  - `monitor_nits` defaults to 200 (HDR→SDR target);
  - crop L/R/T/B default to 0;
  - signal detection is off by default.
- **[O]** The startup log is "Starting macOS grabber. Selected: '{s}' max width: {d} ({d}) @ {d} fps".
- **[I]** The frame is scaled so its width is at most `videoMode` px, keeping the aspect ratio. Capture is timer-driven at `fps`.
- **[O]** The USB grabber has `fpsSoftwareDecimation` (default 1), which processes every n-th frame.

---

## 3. Image → LED mapping (Q3)

### 3.1 Layout to rectangles (classic layout generator, web UI JS `RES:zs_0032d632`) [O]
Every LED is a normalized rectangle `{hmin, hmax, vmin, vmax, group}` in the range 0..1. The rectangles are stored in config, and the core only consumes them.

Defaults (`RES:zs_0026f64d`):
- top=1, bottom=0, left=0, right=0;
- glength=0, gpos=0;
- position=0 (input/start offset);
- groupX=0, groupY=0;
- reverse=false;
- **hdepth=8%**, **vdepth=5%**;
- overlap=0, edgegap=0;
- trapezoid corners: ptl=(0,0), ptr=(100,0), pbl=(0,100), pbr=(100,100).

Generation, as I describe it:
- **Order** is clockwise starting at the top-left corner:
  - top edge from left to right;
  - right edge from top to bottom;
  - bottom edge from right to left;
  - left edge from bottom to top.
- **Top**:
  - the width is split into `top` equal steps after removing a horizontal edge gap on both ends;
  - the rectangle is `[x_i, x_{i+1}]` horizontally and `[0, hdepth]` vertically.
- **Right**:
  - the height is split into `right` steps, with the vertical edge gap removed on both ends;
  - the rectangle is `[1 - vdepth, 1]` horizontally.
- **Bottom**: like top, but vertically `[1 - hdepth, 1]`, iterated in reverse.
- **Left**: like right, but horizontally `[0, vdepth]`, iterated in reverse.
- **Edge gap**:
  - the UI value is a percent;
  - the vertical gap is that value / 100 / 2;
  - the horizontal gap is the vertical gap divided by 16/9, which corrects for the aspect ratio.
- **Overlap**: each rectangle is widened along the strip by `overlap` (a fraction) on both sides, then clamped to 0..1.
- **Trapezoid**: the corner points let the edges be skewed. The defaults give a full rectangle.
- **Gap (glength, gpos)**: removes `glength` consecutive LEDs starting at index `gpos`. This is used for a stand or cable gap.
- **position**: rotates the array. A positive N moves the first N LEDs to the end, which sets where LED #0 physically sits.
- **reverse**: reverses the whole array, which changes the direction to counter-clockwise.
- **groupX/groupY**: optional grouping of LEDs into the same color group, when 2×group ≤ edge count.
- Values are rounded to 4 decimals.
- A separate "matrix" layout also exists:
  - `ledshoriz`/`ledsvert` default 1;
  - `cabling` is snake or parallel;
  - `start` is top-left, top-right, bottom-left or bottom-right.

### 3.2 Color per area (`ImageColorAveraging`) [O] (ev_bd729493, schema `RES:zs_0026bcfa`)
`imageToLedMappingType` defaults to **"advanced"**. The other option is `"unicolor_mean"`.
- **advanced ("Multicolor: precise average color for each LED zone, corrected for image gamma")**:
  - each LED has a precomputed list of pixel offsets inside its rectangle;
  - each pixel's R, G and B (sRGB 8-bit) goes through an **sRGB→linear 16-bit LUT**;
  - the linear values are summed, divided by the pixel count, and normalized by 65535 to give a linear float RGB per LED. **[O]**
  - Processing continues in linear float, and the output stage converts back to 8-bit. **[I]** ("Infinite color engine")
- **unicolor_mean**: one gamma-correct average over the whole screen, applied to all LEDs. **[O text]**
- `sparse_processing` defaults to false. When on, only every second pixel and every second line is sampled. **[O text]**
- **[I]** The rectangle-to-pixel conversion is `floor(hmin*W)..ceil(hmax*W)` with at least one pixel, plus a dedup or large-area threshold. The constructor has a constant 1601. **[U exact rounding]**
- **[U]** The "dominant color" mode does not exist in v22. Only advanced and unicolor are present.

### 3.3 Black-border detection [O] (schema `RES:zs_0026d946`, ev_535728ad)
Defaults:
- **enable=false**;
- **threshold=5%**;
- unknownFrameCnt=600;
- borderFrameCnt=50;
- maxInconsistentCnt=10;
- blurRemoveCnt=1;
- mode="default". The modes are default, classic, osd and letterbox.

Behavior:
- The threshold is converted to `ceil(threshold * 255)`, capped at 255 (constructor).
- A pixel counts as "content" if any channel is above the threshold.
- **Default mode** (process):
  - walk from the edge toward the center;
  - check 3 probe lines at 1/3, 1/2 and 2/3 of the other dimension, in both the horizontal and the vertical direction;
  - the first content pixel gives the border width, up to 1/3 of the dimension;
  - if nothing is found, the result is "unknown" (−1).
- **Classic, osd, letterbox**: variants with different probe positions. **[O names, U details]**
- **Hysteresis**:
  - a new border is accepted after `borderFrameCnt` consistent frames;
  - up to `maxInconsistentCnt` contradicting frames are tolerated;
  - after `unknownFrameCnt` frames with no detection, the border resets to 0;
  - `blurRemoveCnt` extra pixels are cut from the detected border.
- When a border is set, the LED rectangles are mapped into the inner (non-black) image region. **[I from verifyBorder → setSize]**

---

## 4. Color processing (Q4) [O schema `RES:zs_0026bcfa`, code ev_535728ad]
Defaults:
| key | default | range | behavior |
|---|---|---|---|
| temperatureSetting | disabled | cold, neutral, warm, custom | presets fill temperatureR/G/B |
| temperatureRed/Green/Blue | 1.0 | 0–1 | per-channel multiply, clamp 0..1 |
| classic_config | true | | 3-primary RGB calibration (red/green/blue targets). The full mode adds cyan, magenta, yellow, white and black |
| red/green/blue | [255,0,0] / [0,255,0] / [0,0,255] | | calibration targets (identity) |
| scaleOutput | 1.0 | 0–2 | multiply RGB in **linear** space, clamp |
| gamma (user gamma) | **1.5** | 0.1–100 | `v' = v^gamma`. 1.0 disables it |
| luminanceGain | 1.0 | 0–10 | HSV V × gain, clamp 1 |
| saturationGain | 1.0 | 0–10 | HSV S × gain, clamp 1 |
| backlightThreshold | 0.0039 | 0–1 | minimum level (1/255) |
| backlightColored | true | | |
| powerLimit | 1.0 | 0–1 | scales the whole frame down if total power exceeds the limit |

Brightness is luminanceGain. There is no separate "brightness" key in v22's color schema. **[O]**

Algorithms (my own description):
- **User gamma**:
  - a 512-entry table of `x^gamma` is built for x in [0,1];
  - each channel is looked up as `v*511` with linear interpolation between neighbouring entries. **[O]**
- **Brightness and saturation**:
  - convert to HSV (H in degrees, S = (max−min)/max, V = max);
  - V = min(1, V×luminanceGain) and S = min(1, S×saturationGain);
  - convert back. **[O]**
- **Minimal backlight**:
  - "colored" mode: each channel is raised to at least the threshold;
  - otherwise: if the mean of R, G and B is below the threshold, all three are set to the threshold. **[O branch structure; which flag is which is I]**
  - It is disabled during effects, colors and the Off state. **[O text]**
- **Temperature and scale output**: per-channel multiply, clamp 0..1. **[O]**
- **Order of steps** in `applyyAllProcessingSteps`: **[U]**. The likely order is calibration → temperature → scaleOutput → brightness/saturation → user gamma → backlight → power limit. **[I]**
- **HDR**:
  - an LUT-based tone mapping is used for HDR sources (`lut_lin_tables.3d`);
  - automatic tone mapping thresholds are Y180/U175/V160;
  - `monitor_nits` = 200 is the SDR target for the system grabber. It is not needed for an SDR Mac display. **[O]**
- **Output quantization**: the float result is converted to 8-bit per LED. The anti-flicker filter is part of this stage (see §5).

---

## 5. Smoothing (Q5) [O schema `RES:zs_0026df3a`, code ev_535728ad, texts `RES:zs_003239da`]
Defaults:
- **enable=true**;
- **type="HybridRgbInterpolator"**;
- **time_ms=150** (25–5000);
- **updateFrequency=50 Hz** (20–200);
- smoothingFactor=0.0;
- stiffness=150;
- damping=26;
- y_limit=0.03;
- **antiFlickeringFilter=true**;
- continuousOutput=false.

Types:
1. **Stepper ("Linear Interpolator")**:
   - each new target restarts a full-duration linear move from the current color;
   - the elapsed time per tick is capped at 100 ms.
   - Per tick: `k = 1 − remaining/total`, clamped to [1e-4, 1]. The color moves by `k` toward the target, and snaps to it when the difference is below about 1.4e-4. **[O]**
2. **ExponentialInterpolator**:
   - `alpha = 1 − exp(−dt/tau)`, clamped to [1e-4, 1];
   - `current += (target − current) × alpha'`, where alpha' is alpha raised to 0.9, 0.75 or 0.6 (all three powers are computed). **[O constants; I selection by delta magnitude]**
   - Snaps when the max channel difference is below about 1.4e-4.
3. **RgbInterpolator**: a linear path, or with smoothingFactor > 0 a "chasing" ease-in/out. When interrupted, the duration is rescaled to keep the speed constant. **[O text]**
4. **YuvInterpolator**: same idea in YUV, with the per-step change in Y capped at y_limit. **[O text]**
5. **HybridInterpolator (YUV) / HybridRgbInterpolator (default)**:
   - a linear "pacer" moves to the target over time_ms;
   - the output follows the pacer as a damped spring: `a = stiffness·(pacer − x) − damping·v`, integrated each tick;
   - the YUV variant also applies y_limit. **[O text + I formula]**

Other behavior:
- Ticks run at updateFrequency.
- The smoothing clock may force the LED refresh rate. Log: "Ignoring user LED refresh rate. Forcing smoothing refresh rate = {f} Hz". **[O STR:25431]**
- **Anti-flicker filter**: reduces flicker caused by 24-bit quantization at low levels. It is auto-disabled for deep-color drivers. **[O text]** **[I]** It most likely uses temporal dithering or hysteresis on the 8-bit rounding, which avoids toggling between adjacent levels. **[U exact]**
- Effects can have their own smoothing (`edt_eff_smooth_*`). Music effects use 60 Hz when smoothing is on and 20 Hz when it is off. **[O text]**

---

## 6. Effects (Q6) [O names `STR:24239-24264`, classes ev_4a0417f2, params ev_2a13b2f5]
All effects are compiled C++ (`Animation_*`). There are no Python or JSON effect files in v22. Constructor constants are noted where observed. Their meaning is **[I]**.

| Name | Base | Behavior (my words) / observed params |
|---|---|---|
| Rainbow swirl | Swirl | hue wheel rotating around the frame; rotation 20 s |
| Rainbow swirl fast | Swirl | same, 7 s rotation. **Default boot effect, 3000 ms** [O schema] |
| Atomic swirl | Swirl | swirl with a sparse color list (white/blue-ish), 25 s |
| Double swirl | Swirl | two counter-rotating swirls (contains red-ish 0xFF0014 stops) |
| Rainbow waves | base | hue waves moving along the strip |
| Waves with Color | Waves | waves with a user color |
| Sea waves | Waves | blue/green palette (0xFF0008, 0xFF5004 …), speed 1.25 |
| Mood blobs (Blue/Green/Red/Cold/Warm/Full color) | MoodBlobs | slow color blobs drifting around; rotation 20 s, color change 60 s, 5 blobs, hue range varies per variant |
| Breath | Fade | fade in/out of white, 3000 ms, 50 steps |
| Candle | CandleLight | flickering warm orange (≈0x8AFF hue/sat), 4 candles |
| Cinema brighten lights | Fade | fade up to warm white over 5000 ms, then hold |
| Cinema dim lights | Fade | fade down to off |
| Notify blue | Fade | 3 quick blue flashes, 200 ms |
| Strobe red / Strobe white | Fade | fast on/off strobe (white 200 ms) |
| Knight rider | base | a 25-pixel virtual bar with a moving red dot and fading tail |
| Plasma | base | classic plasma sine-sum color field |
| Police Lights Single / Solid | Police | alternating red/blue halves; rotation 1.5 s / 1.0 s (base 2.0 s) |
| Sparks | base | random white sparks on black |
| System Shutdown | base | red sweep / blink, then off, speed 1.2 |
| Music: fullscreen pulse / quatro / stereo / pulse waves / equalizer test (BLUE/GREEN/RED/WHITE/YELLOW/MULTI COLOR [FAST/SLOW]) | AnimationBaseMusic | audio-reactive. These need sound capture |

Common effect parameters across the UI and JSON API:
- `name`
- `priority`
- `duration` (ms; −1 or 0 = infinite)
- `args`
- optional per-effect smoothing (enable, time_ms, updateFrequency)

The UI effect configurator exposes per-effect color, speed and direction when the base supports them. **[O text]**

---

## 7. Priorities and sources (Q7) [O schemas `STR:555-1160, 1925-2390`, web JS `RES:zs_0032b4ef`]
- Lower number wins. The valid user range is **1–253**. 254 is reserved [I] and 255 is the background effect. **[O text: "Always starts with priority channel 255"]**
- Defaults:
  - USB video grabber: **240** (range 100–253);
  - system/screen grabber: **245** (range 100–253);
  - web UI color and effect: priority **1**;
  - the JSON API `color`, `effect` and `image` commands require `priority` and take optional `duration` (ms) and `origin`;
  - boot (foreground) effect: "Rainbow swirl fast" for 3000 ms;
  - background effect: on, type effect, color [255,138,0] in the schema (`STR:2361-2387`). **[O]**
- The muxer (`PriorityMuxer`) keeps entries with a timeout (`timeout_ms`) and shows the active one with the lowest number. `sourceselect` selects one manually and `clear`/`clearall` remove entries. Expired entries drop automatically. **[O names, I semantics]**
- The network receivers (Flatbuffers / Protobuf) have their own priority and a timeout of 5 s. **[O]**

Suggested replica model [I]:
- `colorOverride(1) > effect(user, 1..) > screen(245) > background(255)`;
- each entry has an optional expiry.

---

## 8. Practical recommendations for the Swift replica [I]
1. Use ScreenCaptureKit.
   - `SCScreenshotManager.captureImage` polling at 20–30 fps works, as HyperHDR does it.
   - `SCStream` with `minimumFrameInterval` is more efficient and also works.
   - Downscale to about 512 px wide.
   - Use BGRA in the sRGB color space.
2. Compute the LED rectangles with the classic generator (§3.1). Use defaults of hdepth 8% and vdepth 5%.
3. Average each rectangle in linear light (sRGB→linear LUT), then process.
4. Pipeline:
   - temperature and scale;
   - HSV gain;
   - gamma 1.5;
   - minimum backlight;
   - smoothing at 50 Hz (Hybrid spring, or the simpler exponential with tau ≈ 150 ms);
   - linear→sRGB;
   - quantize to 8-bit with dithering or anti-flicker;
   - color-order permutation;
   - Adalight frame.
5. Serial:
   - open at the sketch's baud (e.g. 115200 or 500000);
   - wait about 2 s, or until `"Ada\n"`, for the DTR auto-reset;
   - send `41 64 61 hi lo chk` + RGB;
   - re-send the last frame about once a second when idle (keepalive);
   - send black on quit.
6. Only use the AWA protocol (`41 77 61 …` + f1 f2 fx) if you flash HyperSerial-compatible firmware. Stock Nano Adalight sketches reject it.

## Unknowns
- The exact order of color-processing steps.
- How the exponential interpolator selects among its three alpha powers.
- The math of the anti-flicker filter.
- The probe positions of the black-border classic, osd and letterbox modes.
- Exact effect palettes and speeds beyond the observed constructor constants.
- The exact rectangle-to-pixel rounding.
