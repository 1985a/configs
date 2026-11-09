#!/usr/bin/env bash
# Deshace el puente creado por bridge_qemu2.sh / puente-win10.sh y devuelve la IP a
# la interfaz física.
#
# Configuración en ~/.config/home-scripts.env o como variables:
#   BRIDGE_IFACE, BRIDGE_NAME, BRIDGE_PRIMARY_ADDR, BRIDGE_ADDR, BRIDGE_GW
# Uso: sudo ./bridge_qemu-disable.sh
set -uo pipefail   # sin -e: si un paso ya estaba deshecho, se sigue con el resto

user_home=$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)
# shellcheck disable=SC1091
[[ -r "$user_home/.config/home-scripts.env" ]] && . "$user_home/.config/home-scripts.env"

IFACE="${BRIDGE_IFACE:-cable0}"
BRIDGE="${BRIDGE_NAME:-kvm_bridge}"
PRIMARY="${BRIDGE_PRIMARY_ADDR:?Define BRIDGE_PRIMARY_ADDR en ~/.config/home-scripts.env}"
ADDR="${BRIDGE_ADDR:?Define BRIDGE_ADDR en ~/.config/home-scripts.env}"
GW="${BRIDGE_GW:?Define BRIDGE_GW en ~/.config/home-scripts.env}"

if (( EUID != 0 )); then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

MAC=$(< "/sys/class/net/$IFACE/address")

set -x

sysctl -w net.ipv4.ip_forward=0
iptables -D FORWARD -m physdev --physdev-is-bridged -j ACCEPT
ebtables -t broute -D BROUTING -d "$MAC" -p ipv4 -j redirect --redirect-target DROP

ip addr del "$ADDR" dev "$BRIDGE"
ip link set "$BRIDGE" down
ip link del "$BRIDGE" type bridge

ip addr replace "$PRIMARY" dev "$IFACE"
ip link set "$IFACE" up
ip route replace default via "$GW" dev "$IFACE"

ip addr show "$IFACE"
