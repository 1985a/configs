#!/usr/bin/env bash
# Reparte en orden (CPU0, CPU1, ...) las IRQs de audio, red y vídeo.
# Uso: sudo ./balance_irqs.sh
set -euo pipefail

# Dispositivos de interés: patrón en /proc/interrupts -> descripción
declare -A DEVICES=(
    ["snd_hda_intel"]="audio"
    ["iwlwifi"]="network"
    ["nvidia"]="video"
)

if (( EUID != 0 )); then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

echo "Buscando IRQs de audio, red y video..."

NUM_CPUS=$(nproc)
CPU_INDEX=0

while read -r line; do
    for dev in "${!DEVICES[@]}"; do
        [[ "$line" == *"$dev"* ]] || continue
        irq="${line%%:*}"
        irq="${irq// /}"
        [[ "$irq" =~ ^[0-9]+$ ]] || continue

        echo "→ IRQ $irq (${DEVICES[$dev]}) será asignado a CPU$CPU_INDEX"
        echo "$CPU_INDEX" > "/proc/irq/$irq/smp_affinity_list" \
            || echo "   (el kernel no permite cambiar la IRQ $irq)"

        CPU_INDEX=$(( (CPU_INDEX + 1) % NUM_CPUS ))
    done
done < /proc/interrupts

echo "Asignación completada."
