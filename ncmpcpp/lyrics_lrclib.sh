#!/bin/bash
# Descarga letras desde lrclib.net (gratis, sin API key) y las guarda en ~/.ncmpcpp/lyrics
# con el mismo nombre que usa ncmpcpp ("Artista - Título.txt"), así ncmpcpp las muestra.
#
# Uso:
#   lyrics_lrclib.sh            -> canción actual y la siguiente de la cola
#   lyrics_lrclib.sh -f         -> igual, pero reemplaza letras que ya existan
#
# Se llama desde ~/.local/bin/ncmpcpp-notify.sh (execute_on_song_change).
# La siguiente canción se baja por adelantado para que ya esté lista cuando empiece.

LYRICS_DIR="${LYRICS_DIR:-$HOME/.ncmpcpp/lyrics}"
API="https://lrclib.net/api"
UA="ncmpcpp-lyrics-script (https://github.com/ncmpcpp/ncmpcpp)"
FORCE=0
[[ "$1" == "-f" ]] && FORCE=1

mkdir -p "$LYRICS_DIR"

fetch_one() {
    local artist="$1" title="$2" album="$3" duration="$4"
    [[ -z "$artist" || -z "$title" ]] && return

    # mismo nombre que genera ncmpcpp: quita \ " * / : < > ? |
    local name="$artist - $title"
    name=${name//[\\\"*\/:<>?|]/}
    local file="$LYRICS_DIR/$name.txt"

    [[ -s "$file" && $FORCE -eq 0 ]] && return

    local args=(-sfG --max-time 10 -A "$UA"
        --data-urlencode "artist_name=$artist"
        --data-urlencode "track_name=$title")
    [[ -n "$album" ]] && args+=(--data-urlencode "album_name=$album")
    [[ -n "$duration" ]] && args+=(--data-urlencode "duration=$duration")

    # 1) coincidencia exacta  2) búsqueda por artista + título
    local json lyrics
    json=$(curl "${args[@]}" "$API/get")
    lyrics=$(jq -r 'if .instrumental then "(Instrumental)" else (.plainLyrics // empty) end' <<<"$json" 2>/dev/null)

    if [[ -z "$lyrics" ]]; then
        json=$(curl -sfG --max-time 10 -A "$UA" \
            --data-urlencode "artist_name=$artist" \
            --data-urlencode "track_name=$title" "$API/search")
        lyrics=$(jq -r 'map(select(.plainLyrics != null and .plainLyrics != "")) | .[0].plainLyrics // empty' <<<"$json" 2>/dev/null)
    fi

    [[ -n "$lyrics" ]] && printf '%s\n' "$lyrics" > "$file"
}

FMT=$'%artist%\x1f%title%\x1f%album%\x1f%time%'  # \x1f: separador que no colapsa campos vacíos

to_seconds() {  # "3:45" o "1:02:03" -> segundos
    local t="$1" s=0 part
    [[ -z "$t" ]] && return
    IFS=: read -ra parts <<<"$t"
    for part in "${parts[@]}"; do s=$((s * 60 + 10#$part)); done
    echo "$s"
}

{
    mpc -f "$FMT" current
    mpc -f "$FMT" queued
} 2>/dev/null | while IFS=$'\x1f' read -r artist title album time; do
    fetch_one "$artist" "$title" "$album" "$(to_seconds "$time")"
done
