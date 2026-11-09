#!/usr/bin/env bash
# Imprime la ruta de una imagen con la carátula de la canción actual de mpd
# (o de la canción indicada como ruta relativa a la biblioteca de mpd).
# Sale con código 1 si no hay carátula (streams, archivos sin imagen...).
#
# Orden de búsqueda:
#   1. imagen incrustada en el archivo (mpc readpicture)
#   2. imagen en la carpeta del disco: cover/folder/front primero, si no la más grande
#
# Las carátulas se guardan en ~/.cache/ncmpcpp-covers para no extraerlas cada vez.
set -u

MUSIC_DIR="${MPD_MUSIC_DIR:-$HOME/Music}"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/ncmpcpp-covers"

rel="${1:-$(mpc -f %file% current 2>/dev/null)}"
[[ -z "$rel" || "$rel" == *://* ]] && exit 1

mkdir -p "$CACHE"
out="$CACHE/$(printf '%s' "$rel" | md5sum | cut -c1-32).jpg"
[[ -s "$out" ]] && { echo "$out"; exit 0; }

is_image() { [[ $(file -b --mime-type "$1") == image/* ]]; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# 1. incrustada
mpc readpicture "$rel" > "$tmp" 2>/dev/null
if ! is_image "$tmp"; then
    # 2. en la carpeta
    dir="$MUSIC_DIR/$(dirname "$rel")"
    img=$(find "$dir" -maxdepth 1 -type f -iregex '.*/\(cover\|folder\|front\|album\)[^/]*\.\(jpe?g\|png\|webp\)' -print -quit 2>/dev/null)
    if [[ -z "$img" ]]; then
        img=$(find "$dir" -maxdepth 1 -type f -iregex '.*\.\(jpe?g\|png\|webp\)' -printf '%s\t%p\n' 2>/dev/null \
            | sort -rn | head -n 1 | cut -f2-)
    fi
    [[ -n "$img" ]] || exit 1
    cp -- "$img" "$tmp" || exit 1
    is_image "$tmp" || exit 1
fi

# normaliza a jpg de máx. 600px (sirve igual para la notificación y para kitty);
# se escribe a un temporal y se renombra para no dejar carátulas a medias en la caché
part="$out.part.$$"
if ffmpeg -nostdin -v error -y -i "$tmp" -frames:v 1 -vf "scale='min(600,iw)':-2" -f mjpeg "$part"; then
    mv -f "$part" "$out"
else
    rm -f "$part"
    exit 1
fi
echo "$out"
