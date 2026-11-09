#!/usr/bin/env bash
# Lista los sensores de temperatura y ventiladores (hwmon) y guarda sus rutas en
# ~/.config/conky/conky_hwmon_paths.sh.
# Nota: la barra actual ya no lo necesita (usa ~/.scripts/scripts/conky_hwmon_auto.sh,
# que busca los sensores por nombre cada vez); sirve para explorar qué hay.
set -euo pipefail

OUTPUT="$HOME/.config/conky/conky_hwmon_paths.sh"
mkdir -p "$(dirname "$OUTPUT")"
: > "$OUTPUT"

for hwmon in /sys/class/hwmon/hwmon*; do
    name=$(< "$hwmon/name")
    echo "== $hwmon ($name)"

    for temp_input in "$hwmon"/temp*_input; do
        [[ -f "$temp_input" ]] || continue
        n=${temp_input##*/temp}; n=${n%_input}
        label="temp$n"
        [[ -r "$hwmon/temp${n}_label" ]] && label=$(< "$hwmon/temp${n}_label")
        echo "   temperatura: $label"
        printf '# %s: %s\nTEMP%s_PATH="%s"\n' "$name" "$label" "$n" "$temp_input" >> "$OUTPUT"
    done

    for fan_input in "$hwmon"/fan*_input; do
        [[ -f "$fan_input" ]] || continue
        n=${fan_input##*/fan}; n=${n%_input}
        echo "   ventilador: fan$n"
        printf '# %s\nFAN%s_PATH="%s"\n' "$name" "$n" "$fan_input" >> "$OUTPUT"
    done
done

echo "Rutas guardadas en $OUTPUT"
