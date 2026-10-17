#!/bin/bash
# Ledly installer.
#   curl -fsSL https://raw.githubusercontent.com/drarekx/ledly/main/install.sh | bash
# Installs or updates Ledly.app in /Applications (or ~/Applications) and opens it.
set -euo pipefail

REPO="drarekx/ledly"
URL="https://github.com/$REPO/releases/latest/download/Ledly.zip"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Ledly solo funciona en macOS."
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || fail "Ledly necesita macOS 14 (Sonoma) o posterior. Tienes $(sw_vers -productVersion)."

bold "Descargando Ledly…"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fL --progress-bar "$URL" -o "$tmp/Ledly.zip" || fail "No se pudo descargar $URL"
ditto -x -k "$tmp/Ledly.zip" "$tmp"
[[ -d "$tmp/Ledly.app" ]] || fail "El archivo descargado no contiene Ledly.app"

# Close a running copy so it can be replaced (it also frees the Arduino's serial port).
if pgrep -x Ledly >/dev/null; then
    bold "Cerrando Ledly…"
    osascript -e 'quit app "Ledly"' 2>/dev/null || true
    sleep 1
    pkill -x Ledly 2>/dev/null || true
fi

dest="/Applications"
if [[ ! -w "$dest" ]]; then
    dest="$HOME/Applications"
    mkdir -p "$dest"
fi
rm -rf "$dest/Ledly.app"
mv "$tmp/Ledly.app" "$dest/"
# The app is not notarized; skip the Gatekeeper prompt for this copy.
xattr -dr com.apple.quarantine "$dest/Ledly.app" 2>/dev/null || true
bold "Instalado en $dest/Ledly.app"

open "$dest/Ledly.app"
bold "¡Listo! Ledly está en la barra de menú."
echo "Siguiente paso: conecta el Arduino Nano por USB y, en Ledly → Dispositivo, pulsa «Instalar firmware»."
echo "La primera vez macOS pide permiso de Grabación de pantalla para leer los colores."
