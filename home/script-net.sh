#!/usr/bin/env bash
# Fija los hilos vhost, las IRQs de vnet/virtio y RPS/XPS de una VM QEMU a las
# CPUs 2-11 (ver checkar-vhost.sh para comprobarlo).
# Uso: sudo ./script-net.sh PID_DE_QEMU
set -euo pipefail

PID=${1:?"Uso: sudo $0 <PID_de_qemu>"}

if (( EUID != 0 )); then
  echo "Ejecuta como root: sudo $0 $PID" >&2
  exit 1
fi

# 1) Pin de hilos vhost a 2-11
for TID in $(ps -T -p "$PID" -o tid,comm | awk '/vhost-/{print $1}'); do
  taskset -pc 2-11 "$TID"
done

# 2) (Opcional) mover el emulador fuera de cores de juego
EMUTID=$(ps -T -p "$PID" -o tid,comm | awk '/qemu-system-x86/{print $1}' | head -n1 || true)
if [ -n "${EMUTID:-}" ]; then taskset -pc 1 "$EMUTID"; fi

# 3) Fijar IRQs de vnet/virtio a 2-11
for IRQ in $(grep -E 'vnet|virtio' /proc/interrupts | awk '{print $1}' | sed 's/://'); do
  echo 2-11 > "/proc/irq/$IRQ/smp_affinity_list"
done

# 4) RPS/XPS
MASK=ffc
for q in /sys/class/net/br0/queues/rx-*; do [ -e "$q" ] && echo "$MASK" > "$q/rps_cpus"; done
for IF in /sys/class/net/vnet*; do
  for q in "$IF"/queues/rx-*; do [ -e "$q" ] && echo "$MASK" > "$q/rps_cpus"; done
done
for IF in br0 vnet0 vnet1; do
  [ -d "/sys/class/net/$IF" ] || continue
  for q in "/sys/class/net/$IF"/queues/tx-*; do echo "$MASK" > "$q/xps_cpus"; done
done

echo "Listo: vhost, IRQs y RPS/XPS fijados."

