#!/usr/bin/env bash
# Decide la ubicación del clima, para que no quede escrita en el repositorio.
# Orden: 1) argumento  2) variable WEATHER_LOCATION  3) ~/.config/weather-location
# Si no hay ninguna, imprime vacío y wttr.in usa la ubicación aproximada de tu IP.
# Se usa con "source" desde weather3.sh y weather_icons.sh.

weather_location() {
    local loc="${1:-${WEATHER_LOCATION:-}}"
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/weather-location"
    if [[ -z "$loc" && -r "$file" ]]; then
        IFS= read -r loc < "$file" || true
    fi
    # wttr.in espera "+" en lugar de espacios
    printf '%s' "${loc// /+}"
}
