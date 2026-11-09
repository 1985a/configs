#!/bin/sh
# Para el ROUTER OpenWrt (BusyBox ash). Carga reglas NAT para que el DNS de la LAN
# (p. ej. AdGuard Home en el propio router) atienda todas las consultas al puerto 53,
# excepto las que vienen de la MAC de la WAN.
#
# Corregido: se puede ejecutar varias veces sin duplicar reglas (borra su tabla
# antes de crearla) y las variables van entre comillas.
set -eu

# Dispositivo real de la WAN (p. ej. eth0 o wan)
WAN_FACE=$(ifstatus wan | jsonfilter -e '@["l3_device"]')
# IP de la WAN
WAN_IP=$(ifstatus wan | jsonfilter -e '@["ipv4-address"][0].address')
# MAC de la WAN
MAC_ADDR=$(ip link show "$WAN_FACE" | awk '/^\s*link\//{print $2}')

if [ -z "$WAN_FACE" ] || [ -z "$WAN_IP" ] || [ -z "$MAC_ADDR" ]; then
    echo "Error: no se pudo leer la interfaz WAN (dispositivo, IP o MAC)." >&2
    exit 1
fi

nft delete table ip nat 2>/dev/null || true
nft add table ip nat
nft -- add chain ip nat prerouting '{ type nat hook prerouting priority -100 ; }'
nft add chain ip nat postrouting '{ type nat hook postrouting priority 100 ; }'
nft add rule ip nat prerouting ether saddr != "$MAC_ADDR" tcp dport 53 fib saddr type != local counter dnat to "$WAN_IP"
nft add rule ip nat prerouting ether saddr != "$MAC_ADDR" udp dport 53 fib saddr type != local counter dnat to "$WAN_IP"
