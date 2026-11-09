#!/usr/bin/env bash
# Muestra qué sensores hwmon informan de consumo eléctrico (power*_input) y su valor.
# Solo lee /sys; no cambia nada.

for h in /sys/class/hwmon/hwmon*; do
    files=("$h"/power*_input)
    [[ -e "${files[0]}" ]] || continue

    name=$(cat "$h/name" 2>/dev/null)
    echo "== $h ($name) =="
    for f in "${files[@]}"; do
        v=$(cat "$f" 2>/dev/null)
        # el kernel da microvatios
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            printf '%s -> %s µW (%s W)\n' "$f" "$v" "$(awk -v x="$v" 'BEGIN { printf "%.2f", x / 1e6 }')"
        else
            printf '%s -> sin lectura\n' "$f"
        fi
    done
done
