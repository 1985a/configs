#!/usr/bin/env bash
# Clima simple para la barra usando wttr.in (sin API key).
# Uso: weather3.sh ["Santo Domingo" | "18.48,-69.91"]
#      Sin argumento usa WEATHER_LOCATION o ~/.config/weather-location
#      (ver weather_location.sh). Salida: "29°C Partly cloudy" o "N/A".
set -uo pipefail

METRIC=1   # 1 = Celsius, 0 = Fahrenheit

# shellcheck source=weather_location.sh
. "$(dirname "$(readlink -f "$0")")/weather_location.sh"
LOC="$(weather_location "${1:-}")"

if (( METRIC )); then UNIT="m"; else UNIT="u"; fi

CURL_OPTS=(-fsSL --connect-timeout 5 --max-time 6 -A "curl")

# %t = temperatura con signo (+29°C), %C = condición
OUT="$(curl "${CURL_OPTS[@]}" "https://wttr.in/${LOC}?format=%t+%C&${UNIT}" 2>/dev/null || true)"

# si falla, al menos la temperatura
if [[ -z "$OUT" ]]; then
    OUT="$(curl "${CURL_OPTS[@]}" "https://wttr.in/${LOC}?format=%t&${UNIT}" 2>/dev/null || true)"
fi

# wttr.in devuelve texto de error en vez de datos cuando está saturado
if [[ -z "$OUT" || "$OUT" == *"Unknown location"* || "$OUT" == *"<"* ]]; then
    echo "N/A"
    exit 0
fi

# quita el "+" inicial y los espacios finales
OUT="${OUT#+}"
printf '%s\n' "${OUT%"${OUT##*[![:space:]]}"}"
