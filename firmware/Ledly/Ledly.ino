// Ledly firmware for Arduino Nano (ATmega328P) + WS2812B strip.
//
// Speaks the Adalight serial protocol:
//   'A' 'd' 'a' <count-1 hi> <count-1 lo> <hi ^ lo ^ 0x55> then count * (R G B)
//
// Ledly extensions (ignored by other Adalight hosts):
//   - On boot it prints "Ada Ledly <version> pin <LED_PIN> max <MAX_LEDS> baud <BAUD>\n".
//     v1 ran at 500000 baud, v2 at 1000000 (16 MHz / 8 / 2: no rounding error).
//   - After every frame has been shown it writes 'k'. The host waits for it
//     before sending the next frame, so no byte arrives while FastLED.show()
//     has interrupts disabled.
//   - With no frame for IDLE_OFF_MS the strip is turned off.
//
// LED_PIN is passed at build time (see firmware/build.sh).

#include <FastLED.h>

#ifndef LED_PIN
#define LED_PIN 6
#endif

#define LEDLY_VERSION "2"
#define BAUD 1000000
#define MAX_LEDS 400
#define IDLE_OFF_MS 15000UL

CRGB leds[MAX_LEDS];
CLEDController *strip;

enum State : uint8_t { MAGIC_A, MAGIC_D, MAGIC_A2, COUNT_HI, COUNT_LO, CHECKSUM };

static State state = MAGIC_A;
static uint8_t countHi, countLo;
static uint16_t ledCount;     // LEDs announced in the header
static uint16_t shownCount;   // LEDs written by the previous show
static uint32_t lastFrame;
static bool idleCleared = true;

// Reads `count` * 3 color bytes straight from the UART.
//
// At 1 Mbaud a byte arrives every 160 CPU cycles, and HardwareSerial's interrupt plus read()
// cost more than that, so long frames overflowed its buffer. Here the RX interrupt is off and
// the data register is polled (~10 cycles a byte). Returns false if the host stops sending.
static bool readColors(uint16_t count) {
  uint8_t *dst = (uint8_t *)leds;
  uint8_t *const end = dst + sizeof(leds);
  uint32_t remaining = (uint32_t)count * 3;
  bool ok = true;

  UCSR0B &= ~_BV(RXCIE0);
  // Bytes HardwareSerial already buffered come first.
  while (remaining && Serial.available() > 0) {
    uint8_t b = Serial.read();
    if (dst < end) *dst++ = b;  // R, G, B in that order
    remaining--;
  }
  while (remaining) {
    uint16_t spins = 0;
    while (!(UCSR0A & _BV(RXC0))) {
      if (++spins == 0) { ok = false; goto done; }  // ~30 ms without data
    }
    uint8_t b = UDR0;
    if (dst < end) *dst++ = b;
    remaining--;
  }
done:
  UCSR0B |= _BV(RXCIE0);
  return ok;
}

// Only pushes the LEDs in use (plus any the last frame lit), so a short strip
// isn't slowed down by MAX_LEDS worth of bit-banging.
static void showFrame() {
  for (uint16_t i = ledCount; i < shownCount && i < MAX_LEDS; i++) leds[i] = CRGB::Black;
  strip->setLeds(leds, min(max(ledCount, shownCount), (uint16_t)MAX_LEDS));
  FastLED.show();
  shownCount = min(ledCount, (uint16_t)MAX_LEDS);
  Serial.write('k');
  lastFrame = millis();
  idleCleared = false;
}

void setup() {
  strip = &FastLED.addLeds<WS2812B, LED_PIN, GRB>(leds, MAX_LEDS);
  FastLED.setDither(0);
  FastLED.setBrightness(255);
  FastLED.clear(true);

  Serial.begin(BAUD);
  Serial.print(F("Ada Ledly " LEDLY_VERSION " pin "));
  Serial.print(LED_PIN);
  Serial.print(F(" max "));
  Serial.print(MAX_LEDS);
  Serial.print(F(" baud "));
  Serial.println(BAUD);
  lastFrame = millis();
}

void loop() {
  while (Serial.available() > 0) {
    uint8_t b = Serial.read();
    switch (state) {
      case MAGIC_A:  state = (b == 'A') ? MAGIC_D : MAGIC_A; break;
      case MAGIC_D:  state = (b == 'd') ? MAGIC_A2 : (b == 'A' ? MAGIC_D : MAGIC_A); break;
      case MAGIC_A2: state = (b == 'a') ? COUNT_HI : (b == 'A' ? MAGIC_D : MAGIC_A); break;
      case COUNT_HI: countHi = b; state = COUNT_LO; break;
      case COUNT_LO: countLo = b; state = CHECKSUM; break;
      case CHECKSUM:
        if (b == (countHi ^ countLo ^ 0x55)) {
          ledCount = ((uint16_t)countHi << 8 | countLo) + 1;
          if (readColors(ledCount)) showFrame();
          state = MAGIC_A;
        } else {
          state = (b == 'A') ? MAGIC_D : MAGIC_A;
        }
        break;
    }
  }

  if (!idleCleared && millis() - lastFrame > IDLE_OFF_MS) {
    strip->setLeds(leds, MAX_LEDS);
    FastLED.clear(true);
    shownCount = 0;
    idleCleared = true;
  }
}
