#!/bin/bash
# Ejecuta un comando y deja su salida lista para ir dentro de un string JSON de swaybar
# Uso en conky: ${exec ~/.scripts/scripts/jsafe.sh comando args...}

out=$("$@" 2>/dev/null | iconv -f utf-8 -t utf-8 -c)
out=${out//$'\n'/ }
out=${out//$'\t'/ }
out=$(printf '%s' "$out" | tr -d '\000-\037\177')
out=${out//\\/\\\\}
out=${out//\"/\\\"}
printf '%s\n' "$out"
