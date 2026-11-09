#!/usr/bin/env bash
# Desinstala apps que no se usan de un televisor Samsung (Tizen) con el modo
# desarrollador activado, usando sdb.
#
# Uso: quitar_apps_tv.sh [IP:PUERTO]   (con la TV encendida)
#   La dirección también puede venir de TV_ADDR en ~/.config/home-scripts.env
#   (antes estaba escrita en el script).
set -uo pipefail

# shellcheck disable=SC1091
[[ -r "$HOME/.config/home-scripts.env" ]] && . "$HOME/.config/home-scripts.env"

TV="${1:-${TV_ADDR:-}}"
if [[ -z "$TV" ]]; then
    echo "Uso: $0 IP:PUERTO   (o define TV_ADDR en ~/.config/home-scripts.env)" >&2
    exit 2
fi

APPS=(
  com.samsung.tv.cobalt-stadia        # Stadia (servicio cerrado)
  com.samsung.tv.cobalt-ytkids        # YouTube Kids (version vieja)
  com.samsung.tv.cobalt-yttv          # YouTube TV
  com.samsung.tv.cobalt-gpm           # Google Play Peliculas
  rJeHak5zRg.Spotify                  # Spotify
  rJeHak5zRg.SpotifyService           # Servicio de recomendaciones de Spotify
  rJeHak5zRg.ContinueWatchingService  # Servicio del mismo paquete de Spotify
)

sdb connect "$TV" || { echo "No se pudo conectar a la TV"; exit 1; }

for app in "${APPS[@]}"; do
  echo "== Desinstalando $app"
  sdb -s "$TV" shell 0 vd_appuninstall "$app"
done

echo
echo "== Verificando lo que quedo:"
sdb -s "$TV" shell 0 applist | grep -iE 'stadia|ytkids|yttv|gpm|rJeHak5zRg' \
  || echo "Todo eliminado."
