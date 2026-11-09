#!/usr/bin/env bash
#
# realtek-lowlatency.sh
# Tuning de baja latencia para NIC Realtek RTL8111/8168/8211/8411 (driver r8169)
#
# Uso:
#   sudo ./realtek-lowlatency.sh eth0
# o, si no pasas interfaz, intenta adivinar una que esté UP.

set -e

DEV="${1:-}"

if [[ -z "$DEV" ]]; then
  # Intenta detectar la primera interfaz UP que no sea loopback
  # (antes "!~ /lo/" descartaba también interfaces como wlo1)
  DEV=$(ip -o link show | awk -F': ' '$2 != "lo" && $0 ~ /state UP/ {print $2; exit}')
fi

if [[ -z "$DEV" ]]; then
  echo "No pude detectar interfaz. Pásala explícitamente: sudo $0 eth0"
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "Este script debe ejecutarse como root (usa sudo)."
  exit 1
fi

if ! command -v ethtool >/dev/null 2>&1; then
  echo "Necesitas ethtool. Instálalo primero (en Arch: sudo pacman -S ethtool)."
  exit 1
fi

echo "=== Tuning de baja latencia para interfaz: $DEV ==="
echo

# 1) Mostrar estado actual (por si luego quieres comparar/revertir)
echo ">> Estado actual:"
ethtool "$DEV" | sed 's/^/  /'
echo
ethtool -k "$DEV" | sed 's/^/  /'
echo

# 2) Forzar 1 Gbit full-duplex con autoneg activado
#    (lo normal en un switch/ONT moderno)
echo ">> Ajustando velocidad/duplex y autoneg..."
ethtool -s "$DEV" speed 1000 duplex full autoneg on || \
  echo "   (No se pudo ajustar speed/duplex/autoneg; quizá no es necesario)"

# 3) Desactivar EEE (Energy Efficient Ethernet) para evitar micro-pauses
echo ">> Desactivando EEE (Energy Efficient Ethernet)..."
ethtool --set-eee "$DEV" eee off 2>/dev/null || \
  echo "   (La NIC/driver no soporta EEE o ya está desactivado)"

# 4) Coalescing agresivo a favor de latencia
#    rx-usecs/tx-usecs 0 = interrupción inmediata
echo ">> Ajustando interrupt coalescing para mínima latencia..."
ethtool -C "$DEV" rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 1 2>/dev/null || \
  echo "   (No se pudo ajustar coalescing; el driver puede limitarlo)"

# 5) Reducir tamaño de ring buffers (colas HW) para disminuir colas internas
#    Si notas pérdida de throughput, prueba con 512 en vez de 256.
echo ">> Reduciendo ring buffers (RX/TX = 256)..."
ethtool -G "$DEV" rx 256 tx 256 2>/dev/null || \
  echo "   (No se pudo ajustar ring size; se mantiene el valor por defecto)"

# 6) Desactivar offloads que pueden acumular paquetes y añadir jitter
#    Desactivamos gro/gso/tso/lro; algunas opciones pueden no existir.
echo ">> Desactivando offloads (GRO/GSO/TSO/LRO)..."
for off in gro gso tso lro; do
  ethtool -K "$DEV" "$off" off 2>/dev/null || \
    echo "   ($off no soportado o ya desactivado)"
done

echo
echo ">> Nuevo estado:"
ethtool "$DEV" | sed 's/^/  /'
echo
ethtool -k "$DEV" | sed 's/^/  /'
echo

echo "=== Listo. Reinicia el tráfico/juegos y prueba jitter/ping. ==="
echo "Si algo no te gusta, un reboot devuelve todo a los valores por defecto del driver."
