#!/usr/bin/env bash
# Igual que bridge_qemu2.sh, pero la interfaz física conserva su propia IP
# (BRIDGE_PRIMARY_ADDR) para no perder una sesión SSH abierta durante el cambio.
#
# Configuración en ~/.config/home-scripts.env o como variables:
#   BRIDGE_IFACE, BRIDGE_NAME, BRIDGE_PRIMARY_ADDR, BRIDGE_ADDR, BRIDGE_GW
# Uso: sudo ./puente-win10.sh       Para deshacerlo: sudo ./bridge_qemu-disable.sh
set -euo pipefail

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

modprobe br_netfilter

# La interfaz física mantiene su IP para no cortar la conexión SSH
ip addr replace "$PRIMARY" dev "$IFACE"
ip link set "$IFACE" up

ip link show "$BRIDGE" &>/dev/null || ip link add name "$BRIDGE" type bridge
ip link set "$IFACE" master "$BRIDGE"

ip addr replace "$ADDR" dev "$BRIDGE"
ip link set "$BRIDGE" up
ip route replace default via "$GW" dev "$BRIDGE"

ebtables -t broute -C BROUTING -d "$MAC" -p ipv4 -j redirect --redirect-target DROP 2>/dev/null \
    || ebtables -t broute -A BROUTING -d "$MAC" -p ipv4 -j redirect --redirect-target DROP

# OJO: "-F FORWARD" borra TODAS las reglas de reenvío existentes, como hacía el original.
iptables -F FORWARD
iptables -I FORWARD -m physdev --physdev-is-bridged -j ACCEPT

sysctl -w net.ipv4.ip_forward=1

ip addr show "$IFACE"
ip addr show "$BRIDGE"
bridge link show
