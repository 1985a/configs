#!/usr/bin/env bash
# Comprueba si tu usuario puede usar prioridad de tiempo real (audio de baja latencia).
# Solo lee información; no cambia nada.

LIMITS=/etc/security/limits.d/99-realtime.conf
USER_NAME=$(id -un)

echo "🔍 Verificación de permisos Realtime en Linux"

printf '\n🧑 Usuario actual: %s\n' "$USER_NAME"
printf '📂 Grupos: '
id -nG "$USER_NAME"

printf '\n📄 Archivo de límites: %s\n' "$LIMITS"
if [[ -f "$LIMITS" ]]; then
    cat "$LIMITS"
else
    echo "❌ No existe. Deberías crearlo si necesitas permisos persistentes."
fi

printf '\n🔍 Buscando configuración PAM (pam_limits.so)\n'
grep pam_limits.so /etc/pam.d/* 2>/dev/null \
    || echo "❌ No se encontró pam_limits.so (riesgo de que limits.conf no tenga efecto)"

printf '\n⚙️ Verificando con rtkit:\n'
if pgrep -x rtkit-daemon >/dev/null; then
    echo "✅ rtkit-daemon está activo"
else
    echo "❌ rtkit-daemon NO está corriendo (se necesita para que usuarios sin privilegios directos puedan usar RT)"
fi

printf '\n📊 Procesos actuales con política realtime:\n'
ps -eLo pid,cls,rtprio,ni,pri,pcpu,comm | awk 'NR > 1 && ($2 == "FF" || $2 == "RR")'
