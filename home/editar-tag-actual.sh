#!/usr/bin/env bash
# Edita título, álbum y artista de la canción que suena en MPD (con kid3-cli) y
# actualiza la base de datos de MPD. Deja en blanco lo que no quieras cambiar.
#
# Corregido: los valores iban entre comillas simples, así que un título con apóstrofo
# ("Don't Cha") rompía el comando de kid3-cli. Ahora se escapan bien.
set -euo pipefail

MUSIC_DIR="${MPD_MUSIC_DIR:-$HOME/Music}"

FILE="$(mpc --format '%file%' current)"
if [[ -z "$FILE" ]]; then
    echo "No hay canción actual en MPD."
    exit 1
fi

FULL_PATH="$MUSIC_DIR/$FILE"
if [[ ! -f "$FULL_PATH" ]]; then
    printf 'No existe el archivo:\n%s\n' "$FULL_PATH"
    exit 1
fi

printf 'Archivo actual:\n%s\n\n' "$FULL_PATH"

read -rp "Título: " TITLE
read -rp "Álbum: " ALBUM
read -rp "Artista: " ARTIST

# kid3-cli: argumento entre comillas dobles, escapando \ y "
kid3_quote() {
    local s="${1//\\/\\\\}"
    printf '"%s"' "${s//\"/\\\"}"
}

CMDS=()
[[ -n "$TITLE"  ]] && CMDS+=(-c "set title $(kid3_quote "$TITLE")")
[[ -n "$ALBUM"  ]] && CMDS+=(-c "set album $(kid3_quote "$ALBUM")")
[[ -n "$ARTIST" ]] && CMDS+=(-c "set artist $(kid3_quote "$ARTIST")")

if (( ${#CMDS[@]} == 0 )); then
    echo "No se escribió ningún dato."
    exit 0
fi

kid3-cli "${CMDS[@]}" "$FULL_PATH"

# actualiza solo la carpeta de esa canción, no toda la biblioteca
mpc update --wait "$(dirname "$FILE")" >/dev/null

printf '\nTags actualizados.\n'
