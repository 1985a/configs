#!/usr/bin/env bash
# Descarga un vídeo de YouTube a la RAM (/dev/shm) y lo reproduce con mpv; al cerrar
# mpv se borra. Sin argumento, busca en YouTube y te deja elegir entre 5 resultados.
#
# Uso: youtube2.sh [URL]
#
# Corregido: usaba la carpeta compartida /dev/shm/yt-dlp y luego "mpv carpeta/*",
# que reproducía también restos de descargas anteriores; ahora cada ejecución usa su
# propia carpeta temporal que se borra al salir. La selección se valida.
set -euo pipefail

for cmd in mpv yt-dlp; do
    command -v "$cmd" >/dev/null || { echo "Error: $cmd no está instalado." >&2; exit 1; }
done

temp_dir=$(mktemp -d /dev/shm/yt-dlp.XXXXXX)
trap 'rm -rf -- "$temp_dir"' EXIT

reproducir() {
    yt-dlp -q --no-part -o "$temp_dir/%(title)s.%(ext)s" "$1"
    mpv "$temp_dir"/*
}

buscar_en_youtube() {
    local busqueda resultados seleccion video_id total
    read -rp "Ingresa los términos de búsqueda: " busqueda

    # yt-dlp imprime título e id en líneas alternas
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

if [[ -z "${1:-}" ]]; then
    buscar_en_youtube
else
    reproducir "$1"
fi
