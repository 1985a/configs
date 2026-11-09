#!/usr/bin/env bash
# Versión mínima del puente para la VM de Windows: crea kvm_bridge, mete la interfaz
# física dentro y le pasa la IP. Sin reglas de cortafuegos (ver bridge_qemu2.sh).
#
# Configuración en ~/.config/home-scripts.env o como variables:
#   BRIDGE_IFACE, BRIDGE_NAME, BRIDGE_ADDR
# Uso: sudo ./bridge-win10.sh
set -euo pipefail

user_home=$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)
# shellcheck disable=SC1091
[[ -r "$user_home/.config/home-scripts.env" ]] && . "$user_home/.config/home-scripts.env"

br_name="${BRIDGE_NAME:-kvm_bridge}"
if_name="${BRIDGE_IFACE:-cable0}"
ip_addr="${BRIDGE_ADDR:?Define BRIDGE_ADDR (p. ej. 192.168.1.250/24) en ~/.config/home-scripts.env}"

if (( EUID != 0 )); then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

ip link show "$br_name" &>/dev/null || ip link add name "$br_name" type bridge
ip addr del "$ip_addr" dev "$if_name" 2>/dev/null || true
ip link set "$if_name" master "$br_name"
ip addr replace "$ip_addr" dev "$br_name"
ip link set dev "$br_name" up

echo "Puente creado y configurado"
