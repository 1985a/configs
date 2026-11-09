#!/usr/bin/env bash
# Muestra qué CPU está atendiendo más cada IRQ de audio, GPU, red y teclado.
# Solo lee /proc/interrupts; no cambia nada.

echo "Analizando IRQs en uso y su CPU dominante..."
grep -Ei 'snd|nvidia|enp|eth|cable|wl|kbd|i8042|atkbd' /proc/interrupts | awk '
{
    max = -1; cpu = -1
    # solo las columnas numéricas son contadores por CPU (antes se comparaban
    # también el tipo y el nombre del dispositivo)
    for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++)
        if ($i + 0 > max) { max = $i + 0; cpu = i - 2 }
    print $1, "→ handled most by CPU" cpu, "(" max " times )", "-", $NF
}'
