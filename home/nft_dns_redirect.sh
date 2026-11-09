#!/bin/sh
# Para el ROUTER OpenWrt (BusyBox ash). Redirige todas las consultas DNS (puerto 53)
# de los clientes hacia la IP WAN del router, salvo las que genera el propio router.
#
# Corregido:
#  - "ip link show wan" fallaba: "wan" es el nombre lógico de OpenWrt; el dispositivo
#    real se saca de ifstatus (l3_device).
#  - Borraba la tabla "ip nat" pero creaba "inet nat": al repetirlo se duplicaban reglas.
#  - Calculaba la MAC pero no la usaba; ahora se excluye lo que sale del propio router
#    con "fib saddr type != local".
# (Sustituye también a script-openwrt.sh, que era una copia idéntica.)
set -eu

WAN_INTERFACE="${WAN_INTERFACE:-wan}"
TABLE_NAME="dnsredir"
CHAIN="prerouting"

WAN_IP=$(ifstatus "$WAN_INTERFACE" | jsonfilter -e '@["ipv4-address"][0].address')
if [ -z "$WAN_IP" ]; then
    echo "Error: no se pudo obtener la IP de la interfaz $WAN_INTERFACE." >&2
    exit 1
fi

# Empieza siempre de cero para que repetir el script no duplique reglas
nft delete table inet "$TABLE_NAME" 2>/dev/null || true
# tabla que creaban las versiones anteriores de este script
nft delete table inet nat 2>/dev/null || true

nft add table inet "$TABLE_NAME"
nft add chain inet "$TABLE_NAME" "$CHAIN" '{ type nat hook prerouting priority -100 ; }'
nft add rule inet "$TABLE_NAME" "$CHAIN" fib saddr type != local udp dport 53 counter dnat ip to "$WAN_IP:53"
nft add rule inet "$TABLE_NAME" "$CHAIN" fib saddr type != local tcp dport 53 counter dnat ip to "$WAN_IP:53"

nft list table inet "$TABLE_NAME"
