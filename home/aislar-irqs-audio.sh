#!/usr/bin/env bash
# Fija las interrupciones (IRQ) de audio y red a CPUs concretas para reducir la latencia.
#
# Antes usaba números de IRQ fijos (94, 75, 30...), pero esos números cambian con el
# hardware, el kernel o el orden de arranque: con el tiempo acabó moviendo la IRQ de
# la NVIDIA y la del wifi pensando que eran la de audio y la de cable0. Ahora busca
# cada dispositivo por su nombre en /proc/interrupts.
#
# Uso: sudo ./aislar-irqs-audio.sh
set -euo pipefail

# nombre del dispositivo en /proc/interrupts -> CPU(s) que lo atenderán
declare -A AFINIDAD=(
    ["snd_hda_intel:card2"]="3"   # tarjeta de sonido principal
    ["cable0"]="4"                # Ethernet
    ["snd_hda_intel:card0"]="2"   # audio interno
    ["snd_hda_intel:card1"]="1"   # audio HDMI de la GPU
)

if (( EUID != 0 )); then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

for dev in "${!AFINIDAD[@]}"; do
    cpus="${AFINIDAD[$dev]}"
    # el nombre del dispositivo es la última columna de /proc/interrupts
    mapfile -t irqs < <(awk -v d="$dev" '$NF == d { sub(":", "", $1); print $1 }' /proc/interrupts)
    if (( ${#irqs[@]} == 0 )); then
        echo "⚠️  $dev: no aparece en /proc/interrupts, se omite"
        continue
    fi
    for irq in "${irqs[@]}"; do
        if echo "$cpus" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null; then
            echo "✅ IRQ $irq ($dev) → CPU $cpus"
        else
            echo "❌ IRQ $irq ($dev): el kernel no permite cambiar su afinidad"
        fi
    done
done
