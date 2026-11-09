#!/usr/bin/env bash
# Reproduce YouTube en mpv sin guardar el vídeo (yt-dlp -> tubería -> mpv).
#
# Uso: youtube3.sh                 pregunta qué buscar
#      youtube3.sh URL             reproduce ese enlace
#      youtube3.sh palabras clave  busca y deja elegir entre 5 resultados
set -euo pipefail

for cmd in mpv yt-dlp; do
    command -v "$cmd" >/dev/null || { echo "Error: $cmd no está instalado." >&2; exit 1; }
done

# acepta youtube.com/watch, youtube.com/shorts, m.youtube.com y youtu.be
es_url_youtube() {
    [[ "$1" =~ ^https?://((www|m)\.)?youtube\.com/(watch\?v=|shorts/) || "$1" =~ ^https?://youtu\.be/ ]]
}

reproducir() {
    yt-dlp -o - "$1" | mpv -
}

buscar_en_youtube() {
    local busqueda="${1:-}" resultados seleccion video_id total
    [[ -n "$busqueda" ]] || read -rp "Ingresa los términos de búsqueda: " busqueda

    resultados=$(yt-dlp "ytsearch5:$busqueda" --get-title --get-id)
    if [[ -z "$resultados" ]]; then
        echo "No se encontraron resultados para '$busqueda'."
        exit 1
    fi

    echo "Resultados de búsqueda:"
    awk 'NR % 2 == 1 { printf "[%d] %s\n", (NR + 1) / 2, $0 }' <<< "$resultados"
    total=$(( $(wc -l <<< "$resultados") / 2 ))

    read -rp "Selecciona el número del video que deseas ver: " seleccion
    if ! [[ "$seleccion" =~ ^[0-9]+$ ]] || (( seleccion < 1 || seleccion > total )); then
        echo "Selección inválida."
        exit 1
    fi
    video_id=$(sed -n "$(( seleccion * 2 ))p" <<< "$resultados")

    echo "Reproduciendo el video seleccionado..."
    reproducir "https://www.youtube.com/watch?v=$video_id"
}

input="$*"
if [[ -z "$input" ]]; then
    buscar_en_youtube
elif es_url_youtube "$input"; then
    echo "Reproduciendo el enlace proporcionado..."
    reproducir "$input"
else
    buscar_en_youtube "$input"
fi
