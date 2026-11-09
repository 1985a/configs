#!/usr/bin/env bash
# Diagnóstico de latencia de audio: procesos en tiempo real, afinidad de CPU y,
# si quieres, pw-top / latencytop / perf top.

# Mostrar procesos con política RT
echo -e "\n🔧 Verificando procesos con Realtime (SCHED_FIFO/RR):\n"
# ps marca SCHED_FIFO como "FF" (antes se buscaba "FIFO" y no aparecía nunca)
ps -eLo pid,cls,rtprio,ni,pri,pcpu,comm | awk '($2 == "FF" || $2 == "RR") && $7 ~ /pipewire|wireplumber|easyeffects|retroarch/'

# Mostrar afinidad actual
echo -e "\n🎯 Afinidad de CPU (taskset actual):\n"
for p in pipewire wireplumber easyeffects retroarch; do
  for pid in $(pidof "$p" 2>/dev/null); do taskset -cp "$pid"; done
done

# Preguntar si se desea usar pw-top
read -rp $'\n🔍 ¿Quieres abrir pw-top en otra ventana? (s/n): ' opt
if [[ "$opt" =~ ^[sS]$ ]]; then
  pw-top
fi

# Preguntar si se desea usar latencytop
if command -v latencytop >/dev/null; then
  read -rp $'\n📡 ¿Deseas ver latencytop? (requiere sudo) (s/n): ' lat
  [[ "$lat" =~ ^[sS]$ ]] && sudo latencytop
else
  echo -e "\n⚠️ latencytop no está instalado."
fi

# Preguntar si se desea usar perf top
if command -v perf >/dev/null; then
  read -rp $'\n📊 ¿Deseas iniciar perf top? (requiere sudo) (s/n): ' perfy
  [[ "$perfy" =~ ^[sS]$ ]] && sudo perf top
else
  echo -e "\n⚠️ perf no está instalado."
fi

echo -e "\n✅ Diagnóstico completado."

