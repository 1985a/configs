#!/bin/bash

# Verifica que el programa "mpv" y "yt-dlp" estén instalados
if ! command -v mpv &> /dev/null; then
    echo "Error: mpv no está instalado. Por favor, instálalo antes de usar este script."
    exit 1
fi

if ! command -v yt-dlp &> /dev/null; then
    echo "Error: yt-dlp no está instalado. Por favor, instálalo antes de usar este script."
    exit 1
fi

# Verifica si se proporcionó un enlace de YouTube
if [ -z "$1" ]; then
    echo "Uso: $0 <URL de YouTube>"
    exit 1
fi

# Asigna el enlace a una variable
youtube_url="$1"

# Reproduce el video usando mpv y yt-dlp
mpv "$youtube_url"
