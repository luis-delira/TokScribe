#!/bin/bash
# Compila TokScribe.app. Usa Xcode si está instalado; si no, las Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

# Desde macOS 27, @State de SwiftUI es una macro cuyo complemento
# (libSwiftUIMacros) viene con Xcode y no con las Command Line Tools.
# Con Xcode presente se usa su toolchain solo para este script, sin tocar
# la configuración del sistema (xcode-select).
XCODE_DEV="/Applications/Xcode.app/Contents/Developer"
if [ -d "$XCODE_DEV" ]; then
  export DEVELOPER_DIR="$XCODE_DEV"
fi

APP_NAME="TokScribe"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

echo "▸ Limpiando…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Compilando ($ARCH, SDK $(basename "$SDK"))…"
xcrun swiftc \
  -O \
  -parse-as-library \
  -swift-version 5 \
  -target "$ARCH-apple-macos26.0" \
  -sdk "$SDK" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

echo "▸ Compilando la herramienta de diagnóstico…"
xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  -target "$ARCH-apple-macos26.0" \
  -sdk "$SDK" \
  Sources/Transcriber.swift Sources/AudioExtractor.swift Tools/TranscribeCLI.swift \
  -o "$BUILD_DIR/tokscribe-cli"
codesign --force --sign - "$BUILD_DIR/tokscribe-cli" >/dev/null 2>&1

echo "▸ Empaquetando…"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Binarios auxiliares (yt-dlp). Si no están, la app usa los del sistema.
if [ -d "Resources/bin" ] && [ -n "$(ls -A Resources/bin 2>/dev/null)" ]; then
  echo "▸ Empaquetando dependencias…"
  mkdir -p "$APP/Contents/Resources/bin"
  cp -R Resources/bin/* "$APP/Contents/Resources/bin/"
  chmod +x "$APP/Contents/Resources/bin/"*
  for tool in "$APP/Contents/Resources/bin/"*; do
    echo "    $(basename "$tool") ($(du -h "$tool" | cut -f1))"
  done
else
  echo "▸ Sin dependencias empaquetadas (se usará el yt-dlp del sistema)."
  echo "    Ejecuta ./bundle-deps.sh para incluirlo dentro de la app."
fi

echo "▸ Generando icono…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
if xcrun swift Tools/MakeIcon.swift "$ICONSET" >/dev/null 2>&1; then
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
else
  echo "  (se omitió el icono personalizado)"
fi

echo "▸ Firmando localmente…"
# Los binarios anidados se firman primero, si no la firma de la app no valida.
if [ -d "$APP/Contents/Resources/bin" ]; then
  for tool in "$APP/Contents/Resources/bin/"*; do
    codesign --force --sign - --timestamp=none "$tool" >/dev/null 2>&1 || true
  done
fi
codesign --force --sign - --timestamp=none "$APP" >/dev/null

# Última barrera: no declarar éxito con un paquete incompleto.
for required in "Contents/MacOS/$APP_NAME" "Contents/Info.plist"; do
  if [ ! -f "$APP/$required" ]; then
    echo "✗ Falta $required: la app NO se generó correctamente." >&2
    exit 1
  fi
done

echo "✓ Listo: $(pwd)/$APP"
