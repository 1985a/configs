#!/usr/bin/env bash
# Icono del clima (Nerd Font) con día/noche, usando wttr.in en JSON.
# Uso: weather_icons.sh ["Santo Domingo" | "18.48,-69.91"]
#      Sin argumento usa WEATHER_LOCATION o ~/.config/weather-location.
# Requiere: curl, jq
set -uo pipefail

ICON_CLOUD=$'\xef\x83\x82'   # nf-fa-cloud
ICON_MOON=$'\xef\x86\x86'    # nf-fa-moon_o
ICON_SUN=$'\xef\x86\x85'     # nf-fa-sun_o
ICON_RAIN=$'\xef\x83\xa9'    # nf-fa-umbrella
ICON_STORM=$'\xef\x83\xa7'   # nf-fa-bolt
ICON_SNOW=$'\xef\x8b\x9c'    # nf-fa-snowflake_o
ICON_FOG=$'\xef\x9d\x9f'     # niebla (si tu fuente no lo trae, usa ICON_CLOUD)
ICON_WIND=$'\xef\x9c\xae'    # viento (si tu fuente no lo trae, usa ICON_CLOUD)

# shellcheck source=weather_location.sh
. "$(dirname "$(readlink -f "$0")")/weather_location.sh"
LOC="$(weather_location "${1:-}")"

J="$(curl -fsSL --connect-timeout 5 --max-time 6 -A "curl" \
    "https://wttr.in/${LOC}?format=j1" 2>/dev/null || true)"
[[ -z "$J" ]] && { printf '%s\n' "$ICON_CLOUD"; exit 0; }

# una sola pasada de jq: condición, amanecer y atardecer separados por tabuladores
IFS=$'\t' read -r COND SUNRISE SUNSET < <(jq -r '[
    (.current_condition[0].weatherDesc[0].value // ""),
    (.weather[0].astronomy[0].sunrise // "06:00 AM"),
    (.weather[0].astronomy[0].sunset  // "06:00 PM")
  ] | @tsv' <<< "$J" 2>/dev/null)
COND="${COND,,}"

# "06:24 AM" -> minutos desde las 00:00
to_min() {
    local hm="${1%% *}" ampm="${1##* }" h m
    h="${hm%%:*}"; m="${hm#*:}"
    [[ "$h" =~ ^[0-9]+$ && "$m" =~ ^[0-9]+$ ]] || { echo 0; return; }
    h=$((10#$h)); m=$((10#$m))
    [[ "${ampm^^}" == "PM" && $h -lt 12 ]] && h=$((h + 12))
    [[ "${ampm^^}" == "AM" && $h -eq 12 ]] && h=0
    echo $((h * 60 + m))
}

# wttr.in ya no manda la hora local en el JSON: se usa la del sistema
now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
night=0
if (( now < $(to_min "${SUNRISE:-06:00 AM}") || now >= $(to_min "${SUNSET:-06:00 PM}") )); then
    night=1
fi

# El orden importa: "light snow showers" o "rain with thunder" deben caer en nieve
# y tormenta, no en lluvia; "partly cloudy" debe ir antes que "cloud".
case "$COND" in
    *thunder*|*storm*)                    icon="$ICON_STORM" ;;
    *snow*|*sleet*|*blizzard*|*ice*|*flurries*) icon="$ICON_SNOW" ;;
    *rain*|*shower*|*drizzle*)            icon="$ICON_RAIN" ;;
    *fog*|*mist*|*haze*|*smoke*)          icon="$ICON_FOG" ;;
    *partly*|*sunny*|*clear*)
        if (( night )); then icon="$ICON_MOON"; else icon="$ICON_SUN"; fi ;;
    *cloud*|*overcast*)                   icon="$ICON_CLOUD" ;;
    *wind*|*breeze*|*gale*)               icon="$ICON_WIND" ;;
    *)                                    icon="$ICON_CLOUD" ;;
esac

printf '%s\n' "$icon"
