#!/usr/bin/env bash
# Prueba de carga de un stream de audio: abre N clientes simultáneos durante unos
# segundos y descarta lo que reciben.
#
# Uso: test-mpd.sh [URL] [CLIENTES] [SEGUNDOS]
#   La URL también puede venir de STREAM_URL en ~/.config/home-scripts.env.
#
# Corregido: usaba la variable SECONDS, que en bash es el contador interno de segundos
# del shell; ahora se llama DURATION. La URL ya no está fija en el script, y ya no se
# usa "curl -k" (aceptar certificados inválidos) salvo que pongas INSECURE=1.
set -euo pipefail

# shellcheck disable=SC1091
[[ -r "$HOME/.config/home-scripts.env" ]] && . "$HOME/.config/home-scripts.env"

URL="${1:-${STREAM_URL:-}}"
CLIENTS="${2:-25}"
DURATION="${3:-120}"

if [[ -z "$URL" ]]; then
    echo "Uso: $0 URL [CLIENTES] [SEGUNDOS]   (o define STREAM_URL)" >&2
    exit 2
fi
[[ "$CLIENTS" =~ ^[0-9]+$ && "$DURATION" =~ ^[0-9]+$ ]] || {
    echo "CLIENTES y SEGUNDOS deben ser números" >&2
    exit 2
}

CURL_EXTRA=""
[[ "${INSECURE:-0}" == "1" ]] && CURL_EXTRA="-k"

echo "URL: $URL"
echo "Clientes simulados: $CLIENTS"
echo "Duración: $DURATION segundos"
echo

# shellcheck disable=SC2016  # las $ son del sh hijo, no de este script
seq 1 "$CLIENTS" | xargs -P "$CLIENTS" -I{} sh -c '
    echo "Cliente $1 conectado"
    curl $4 -sL --max-time "$3" -o /dev/null "$2"
    echo "Cliente $1 desconectado"
' sh {} "$URL" "$DURATION" "$CURL_EXTRA"

echo
echo "Prueba terminada."
