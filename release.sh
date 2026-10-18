#!/bin/zsh
# Publishes a Ledly release from this Mac, signed with the local Apple Development
# certificate, so the Screen Recording permission survives auto-updates (macOS ties it
# to the signature; CI has no certificate and could only sign ad-hoc).
#
#   ./release.sh 1.1.0
#
# Builds universal, checks the signature, tags vX.Y.Z, pushes the tag and creates the
# GitHub release with Ledly.zip + Ledly.zip.sha256 (what Updater.swift and install.sh use).
set -euo pipefail
cd "$(dirname "$0")"

fail() { printf "\033[31mError:\033[0m %s\n" "$*" >&2; exit 1; }
bold() { printf "\033[1m%s\033[0m\n" "$*"; }

VERSION=${1:-}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Uso: ./release.sh X.Y.Z"
TAG="v$VERSION"

[[ "$(git branch --show-current)" == "main" ]] || fail "Publica desde main."
[[ -z "$(git status --porcelain)" ]] || fail "Hay cambios sin commit."
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main no está igual que origin/main (haz push o pull)."
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && fail "La etiqueta $TAG ya existe."
gh release view "$TAG" >/dev/null 2>&1 && fail "El release $TAG ya existe."

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')}
[[ -n "$IDENTITY" ]] || fail "No hay certificado «Apple Development» en el llavero; sin él, macOS pediría de nuevo el permiso tras cada actualización."

# The CI build must be green for this commit.
ci=$(gh run list --workflow build.yml --commit "$(git rev-parse HEAD)" --limit 1 \
      --json status,conclusion -q '.[0] | if .status == "completed" then .conclusion else "en curso" end' 2>/dev/null || true)
[[ "$ci" == "success" ]] || fail "La compilación de GitHub (build.yml) de este commit no está en verde (estado: ${ci:-sin ejecutar}). Espera a que acabe o revísala."

bold "Compilando Ledly $VERSION…"
SIGN_IDENTITY="$IDENTITY" VERSION="$VERSION" BUILD="$(git rev-list --count HEAD)" ./build-app.sh

codesign --verify --deep --strict build/Ledly.app || fail "La firma no es válida."
codesign -dv build/Ledly.app 2>&1 | grep -q "Signature=adhoc" && fail "La app quedó firmada ad-hoc."
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Ledly.app/Contents/Info.plist)" == "$VERSION" ]] || fail "Versión incorrecta en Info.plist."
(cd build && shasum -a 256 Ledly.zip | awk '{print $1}' > Ledly.zip.sha256)

bold "Publicando $TAG…"
git tag "$TAG"
git push -q origin "$TAG"
gh release create "$TAG" build/Ledly.zip build/Ledly.zip.sha256 --title "Ledly $TAG" --generate-notes
bold "Listo: $(gh release view "$TAG" --json url -q .url)"
echo "Las apps instaladas se actualizarán solas; para esta: ./build-app.sh no hace falta, usa el menú → Buscar actualizaciones."
