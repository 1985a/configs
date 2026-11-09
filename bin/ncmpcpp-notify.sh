#!/usr/bin/env bash
# Notificación de "canción nueva" para ncmpcpp (execute_on_song_change en
# ~/.ncmpcpp/config): muestra artista - título con la carátula y baja las letras.
set -u

# ncmpcpp puede lanzarse desde tmux o ssh sin las variables de la sesión gráfica
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

SONG="$(mpc current 2>/dev/null)"
[[ -z "$SONG" ]] && exit 0

# carátula como icono si la hay (incrustada o en la carpeta del disco)
ICON="$("$HOME/.ncmpcpp/cover.sh" 2>/dev/null)"
notify-send -a ncmpcpp "Now Playing ♫" "$SONG" --icon="${ICON:-media-playback-start-symbolic}"

# letras desde lrclib.net (actual + siguiente), en segundo plano
"$HOME/.ncmpcpp/lyrics_lrclib.sh" >/dev/null 2>&1 &
