#!/usr/bin/env bash
# Canción actual de MPD con desplazamiento (scroll) para la barra.
# Cada llamada avanza un carácter; la posición se guarda en $XDG_RUNTIME_DIR
# (privado del usuario) y no en /tmp, donde cualquiera podría crear ese archivo.
set -u

ICON_STOP=$'\xef\x81\x8d'    # nf-fa-stop
ICON_PLAY=$'\xef\x81\x8b'    # nf-fa-play
ICON_PAUSE=$'\xef\x81\x8c'   # nf-fa-pause

LEN="${MPD_SCROLL_LEN:-30}"  # caracteres visibles
PAD="   "                    # separación entre repeticiones
POSFILE="${XDG_RUNTIME_DIR:-/tmp}/mpd_scroll.$(id -u).pos"

# Una sola llamada a mpc: la 1.ª línea es la canción y la 2.ª el estado.
# Si MPD está parado, mpc solo imprime la línea de volumen.
mapfile -t status < <(mpc status 2>/dev/null)

icon="$ICON_STOP"
title=""
if (( ${#status[@]} >= 3 )); then
    case "${status[1]}" in
        "[playing]"*) icon="$ICON_PLAY" ;;
        "[paused]"*)  icon="$ICON_PAUSE" ;;
    esac
    # sin escapar todavía: escapar antes de recortar puede partir un \" y romper el JSON
    title=$(printf '%s' "${status[0]}" | iconv -f utf-8 -t utf-8 -c | tr -d '\000-\037\177')
fi

if [[ -z "$title" ]]; then
    printf '%s\n' "$icon"
    exit 0
fi

pos=0
[[ -r "$POSFILE" ]] && read -r pos < "$POSFILE"
[[ "$pos" =~ ^[0-9]+$ ]] || pos=0

cycle=$(( ${#title} + ${#PAD} ))
(( pos >= cycle )) && pos=0

text="$title$PAD$title$PAD$title"
scroll=${text:pos:LEN}
printf '%s\n' "$(( (pos + 1) % cycle ))" > "$POSFILE"

# escapado para que la salida pueda ir dentro de un string JSON
scroll=${scroll//\\/\\\\}
scroll=${scroll//\"/\\\"}
printf '%s %s\n' "$icon" "$scroll"
