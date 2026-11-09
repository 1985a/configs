#!/usr/bin/env bash
# Convierte el historial de zsh (formato ": 1700000000:0;comando") a
# "AAAA-MM-DD HH:MM:SS;comando".
#
# Uso: zshistory.sh [ARCHIVO]     (por defecto ~/.zsh_history)
#
# Antes lanzaba echo, cut, cut y date por cada línea (minutos con un historial de
# varios MB); ahora lo hace todo un solo proceso awk.
set -euo pipefail

file="${1:-$HOME/.zsh_history}"
[[ -r "$file" ]] || { echo "No se puede leer $file" >&2; exit 1; }

# strftime es de gawk; LC_ALL=C evita que awk tropiece con bytes no UTF-8 del historial
LC_ALL=C gawk '
    /^: [0-9]+:[0-9]+;/ {
        split($0, parts, ";")
        ts = substr(parts[1], 3)
        sub(/:.*/, "", ts)
        cmd = substr($0, length(parts[1]) + 2)
        print strftime("%Y-%m-%d %H:%M:%S", ts) ";" cmd
        next
    }
    { print ";" $0 }
' "$file"
