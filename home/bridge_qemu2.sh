#!/usr/bin/env bash
# Crea un puente de red (kvm_bridge) para máquinas virtuales QEMU/KVM, pasando la IP
# de la interfaz física al puente.
#
# Configuración (IPs de tu red) en ~/.config/home-scripts.env o como variables:
#   BRIDGE_IFACE, BRIDGE_NAME, BRIDGE_ADDR, BRIDGE_GW   (ver local.example/)
# Uso: sudo ./bridge_qemu2.sh       Para deshacerlo: sudo ./bridge_qemu-disable.sh
set -euo pipefail

# carga ~/.config/home-scripts.env del usuario real aunque se ejecute con sudo
user_home=$(getent passwd "${SUDO_USER:-$(id -un)}" | cut -d: -f6)
# shellcheck disable=SC1091
[[ -r "$user_home/.config/home-scripts.env" ]] && . "$user_home/.config/home-scripts.env"

IFACE="${BRIDGE_IFACE:-cable0}"
BRIDGE="${BRIDGE_NAME:-kvm_bridge}"
ADDR="${BRIDGE_ADDR:?Define BRIDGE_ADDR (p. ej. 192.168.1.10/24) en ~/.config/home-scripts.env}"
GW="${BRIDGE_GW:?Define BRIDGE_GW (p. ej. 192.168.1.1) en ~/.config/home-scripts.env}"

if (( EUID != 0 )); then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

# MAC de la interfaz física (antes estaba escrita a mano en el script)
MAC=$(< "/sys/class/net/$IFACE/address")

set -x

# Carga el módulo br_netfilter para permitir el filtrado de tráfico en puentes
modprobe br_netfilter

# Quita la IP de la interfaz física (si la tenía)
ip addr del "$ADDR" dev "$IFACE" 2>/dev/null || true
ip link set "$IFACE" up

# Crea el puente si no existe
ip link show "$BRIDGE" &>/dev/null || ip link add name "$BRIDGE" type bridge

# Añade la interfaz física al puente
ip link set "$IFACE" master "$BRIDGE"

# Asigna la IP al puente y lo activa
ip addr replace "$ADDR" dev "$BRIDGE"
ip link set "$BRIDGE" up

# Puerta de enlace predeterminada por el puente
ip route replace default via "$GW" dev "$BRIDGE"

# Lo dirigido a la MAC del anfitrión se enruta en vez de puentearse
# (-C comprueba si la regla ya existe para no duplicarla)
ebtables -t broute -C BROUTING -d "$MAC" -p ipv4 -j redirect --redirect-target DROP 2>/dev/null \
    || ebtables -t broute -A BROUTING -d "$MAC" -p ipv4 -j redirect --redirect-target DROP

# Permite el reenvío de tráfico puenteado.
# OJO: "-F FORWARD" borra TODAS las reglas de reenvío existentes, como hacía el original.
iptables -F FORWARD
iptables -I FORWARD -m physdev --physdev-is-bridged -j ACCEPT

# Habilita el reenvío de paquetes IPv4
sysctl -w net.ipv4.ip_forward=1

# Muestra el estado final
ip addr show "$BRIDGE"
bridge link show
