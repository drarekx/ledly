#!/bin/zsh
# Compiles the Nano firmware once per data pin (D2–D13) into firmware/hex/ledly-pinN.hex.
# The .hex files are committed and bundled into the app, so building the app
# does not need the AVR toolchain. Requires: brew install arduino-cli,
# arduino-cli core install arduino:avr, arduino-cli lib install FastLED@3.7.8 (3.10 fails on avr-gcc 14).
#
# Arduino's bundled avr-gcc is x86_64 only. Without Rosetta, use the native one:
#   brew tap osx-cross/avr && brew install avr-gcc@14
# The script picks it up automatically when present.
set -euo pipefail
cd "$(dirname "$0")"

OUT=hex
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

TOOLCHAIN=()
if [[ -x /opt/homebrew/opt/avr-gcc@14/bin/avr-gcc ]]; then
  # Arduino expects gcc and binutils in one folder.
  mkdir -p "$WORK/bin"
  ln -s /opt/homebrew/opt/avr-gcc@14/bin/* /opt/homebrew/opt/avr-binutils/bin/* "$WORK/bin/" 2>/dev/null || true
  TOOLCHAIN=(--build-property "compiler.path=$WORK/bin/"
    # Its ctags is x86_64 too; the sketch declares everything before use, so skip it.
    --build-property "tools.ctags.pattern=/usr/bin/true")
fi

for PIN in {2..13}; do
  arduino-cli compile --fqbn arduino:avr:nano "${TOOLCHAIN[@]}" \
    --build-property "compiler.cpp.extra_flags=-DLED_PIN=$PIN" \
    --output-dir "$WORK/$PIN" Ledly >/dev/null
  cp "$WORK/$PIN/Ledly.ino.hex" "$OUT/ledly-pin$PIN.hex"
  echo "pin $PIN → $OUT/ledly-pin$PIN.hex"
done
