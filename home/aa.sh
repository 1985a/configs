#!/usr/bin/env bash
# Arregla el modo del monitor DisplayPort al volver de la suspensión (sway + NVIDIA).
#
# Es un "hook" de systemd-sleep: se instala como root en
#   /usr/lib/systemd/system-sleep/sway-dp-fix   (con permisos de ejecución)
# y systemd lo llama con "pre" o "post" al suspender y al despertar.
#
# Antes tenía fijo un nombre de usuario que no existía y solo pasaba XDG_RUNTIME_DIR, pero swaymsg
# necesita SWAYSOCK para encontrar sway, así que nunca llegaba a funcionar.
# Ahora busca la sesión de sway que esté abierta.
set -u

OUT="${SWAY_DP_OUTPUT:-DP-2}"
MODE="${SWAY_DP_MODE:-2560x1440@119.998Hz}"

[[ "${1:-}" == "post" ]] || exit 0

# Espera a que el stack gráfico vuelva
sleep 2

for sock in /run/user/*/sway-ipc.*.sock; do
    [[ -S "$sock" ]] || continue
    uid=$(stat -c %u "$sock")
    user=$(id -nu "$uid") || continue

    swaymsg_as_user() {
        runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" SWAYSOCK="$sock" \
            swaymsg "$@" >/dev/null 2>&1 || true
    }

    swaymsg_as_user output "$OUT" dpms off
    sleep 0.5
    swaymsg_as_user output "$OUT" dpms on
    swaymsg_as_user output "$OUT" mode "$MODE"
done
