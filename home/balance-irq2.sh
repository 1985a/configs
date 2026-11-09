#!/usr/bin/env bash
# Reparte las IRQs de audio, vídeo y red entre varias CPUs y después muestra qué CPU
# atiende más cada una.
#
# Corregido: con "set -e", "((idx++))" y "((cpu_index=...))" devuelven error cuando
# el resultado es 0 y el script se cortaba en la primera vuelta. Además el contador
# de CPU vivía dentro de una tubería ("grep | while") y se perdía entre dispositivos.
#
# Uso: sudo ./balance-irq2.sh
set -euo pipefail

# CPUs disponibles para asignación (ajusta según tu sistema)
CPUS=(0 1 2 3 4 5)

# Dispositivos clave a buscar
device_keywords=(nvidia snd_hda iwlwifi)

if (( EUID != 0 )); then
    echo "Ejecuta como root: sudo $0" >&2
    exit 1
fi

cpu_index=0
printf '\nBuscando IRQs de audio, video y red...\n'

for keyword in "${device_keywords[@]}"; do
    while read -r irq_num; do
        cpu=${CPUS[cpu_index]}
        printf '➔ IRQ %s (%s) será asignado a CPU%s\n' "$irq_num" "$keyword" "$cpu"
        echo "$cpu" > "/proc/irq/$irq_num/smp_affinity_list" \
            || echo "   (el kernel no permite cambiar la IRQ $irq_num)"
        cpu_index=$(( (cpu_index + 1) % ${#CPUS[@]} ))
    done < <(grep -i "$keyword" /proc/interrupts | cut -d: -f1 | tr -d ' ')
done

printf '\nAsignación completada.\n\n'
echo "Analizando IRQs en uso y su CPU dominante..."

for keyword in "${device_keywords[@]}"; do
    grep -i "$keyword" /proc/interrupts | awk '
    {
        max = -1; cpu = -1
        # columnas 2.. son contadores por CPU mientras sean números
        for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++)
            if ($i + 0 > max) { max = $i + 0; cpu = i - 2 }
        sub(":", "", $1)
        printf "➔ IRQ %s handled most by CPU%d - %s\n", $1, cpu, $NF
    }'
done
