#!/usr/bin/env bash
# Da prioridad de tiempo real (SCHED_FIFO) y fija CPUs a los procesos de audio y a
# RetroArch. Pide sudo para chrt/taskset.
#
# Corregido: si un programa tenía varios procesos, pidof devolvía varios PID juntos
# ("123 456") y chrt/taskset fallaban; ahora se aplica a cada uno.

set_realtime() {
    local name="$1" rtprio="$2" cpus="$3" pids pid

    pids=$(pidof "$name") || {
        echo "⚠️  Proceso $name no está en ejecución."
        return
    }

    for pid in $pids; do
        echo "🎯 Aplicando RT y afinidad a $name (PID $pid)..."
        sudo chrt -f -p "$rtprio" "$pid" && echo "✅ $name: RT prioridad $rtprio aplicada."
        sudo taskset -cp "$cpus" "$pid" >/dev/null && echo "✅ $name: Afinidad asignada a CPU(s) $cpus."
    done
}

echo "🔧 Aplicando configuración realtime..."

set_realtime pipewire 90 2,3
set_realtime wireplumber 80 2,3
set_realtime easyeffects 85 2,3
set_realtime retroarch 70 4,5

echo "✅ Todo aplicado. Verifica con:"
echo "   ps -eLo pid,cls,rtprio,ni,pri,pcpu,comm | grep -E 'pipewire|easyeffects|retroarch|wireplumber'"
