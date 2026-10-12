#!/bin/bash
# Descarga el binario autónomo oficial de yt-dlp y lo deja en Resources/bin/,
# para que build.sh lo empaquete dentro de TokScribe.app.
#
# Así la app funciona en cualquier Mac sin Homebrew ni Python.
# yt-dlp es de dominio público (Unlicense), así que redistribuirlo es legal
# incluso en una app comercial de código cerrado.
#
# ffmpeg NO se empaqueta a propósito: el de Homebrew viene con --enable-gpl,
# y la conversión de audio ya se hace de forma nativa con AVFoundation.
set -euo pipefail
cd "$(dirname "$0")"

DEST="Resources/bin"
BINARY="$DEST/yt-dlp"
URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

mkdir -p "$DEST"

echo "▸ Descargando yt-dlp (binario autónomo para macOS)…"
echo "  Origen: $URL"
curl -L --fail --progress-bar -o "$BINARY.tmp" "$URL"

chmod +x "$BINARY.tmp"

echo "▸ Comprobando que el binario funciona…"
if ! "$BINARY.tmp" --version >/dev/null 2>&1; then
  rm -f "$BINARY.tmp"
  echo "✗ El binario descargado no se ejecutó correctamente. No se instaló nada."
  exit 1
fi

VERSION="$("$BINARY.tmp" --version 2>/dev/null | head -1)"
mv "$BINARY.tmp" "$BINARY"

echo "✓ yt-dlp $VERSION listo en $BINARY ($(du -h "$BINARY" | cut -f1))"
echo "  Ahora ejecuta ./build.sh para empaquetarlo dentro de la app."
