#!/bin/bash

# === Información del CPU ===
cpu_model=$(lscpu | awk -F: '/^Model name/ {gsub(/^[ \t]+/, "", $2); print $2}')
sockets=$(lscpu | awk -F: '/^Socket\(s\)/ {gsub(/ /,""); print $2}')
cores_per_socket=$(lscpu | awk -F: '/^Core\(s\) per socket/ {gsub(/ /,""); print $2}')
threads_per_core=$(lscpu | awk -F: '/^Thread\(s\) per core/ {gsub(/ /,""); print $2}')
logical_cpus=$(lscpu | awk -F: '/^CPU\(s\)/ {gsub(/ /,""); print $2}')
total_cores=$((sockets * cores_per_socket))

[[ "$threads_per_core" -gt 1 ]] && smt_status="🟢 SMT (Simultaneous Multithreading) está ACTIVADO" || smt_status="🔴 SMT (Simultaneous Multithreading) está DESACTIVADO"

vcore=""
power_watts=""
cpu_temp=""
freq_avg=""

# === Buscar Vcore ===
for dir in /sys/class/hwmon/hwmon*; do
  for file in "$dir"/in*_label; do
    [[ -f "$file" ]] || continue
    if grep -qiE 'vcore|cpu vdd' "$file" 2>/dev/null; then
      input_file="${file/_label/_input}"
      raw_v=$(cat "$input_file" 2>/dev/null)
      if [[ "$raw_v" =~ ^[0-9]+$ ]]; then
        vcore=$(awk "BEGIN { printf \"%.3f\", $raw_v / 1000 }")
        break 2
      fi
    fi
  done
done

if [[ -z "$vcore" ]]; then
  for dir in /sys/class/hwmon/hwmon*; do
    for vin in "$dir"/in*_input; do
      [[ -f "$vin" ]] || continue
      raw=$(cat "$vin" 2>/dev/null)
      if [[ "$raw" =~ ^[0-9]+$ ]]; then
        volts=$(awk "BEGIN { printf \"%.3f\", $raw / 1000 }")
        if (( $(echo "$volts >= 0.8 && $volts <= 1.4" | bc -l) )); then
          vcore_candidates+=("$volts")
        fi
      fi
    done
  done
  if [[ ${#vcore_candidates[@]} -gt 0 ]]; then
    vcore=$(printf "%s\n" "${vcore_candidates[@]}" | sort -nr | head -n1)
  fi
fi

# === Buscar consumo desde zenpower ===
for dir in /sys/class/hwmon/hwmon*; do
  name=$(cat "$dir/name" 2>/dev/null)
  if [[ "$name" =~ zenpower ]]; then
    raw_p=$(cat "$dir/power1_input" 2>/dev/null)
    if [[ "$raw_p" =~ ^[0-9]+$ ]]; then
      power_watts=$(awk "BEGIN { printf \"%.2f\", $raw_p / 1000000 }")
    fi
    break
  fi
done

# === Buscar temperatura tdie o tctl ===
for dir in /sys/class/hwmon/hwmon*; do
  for tfile in "$dir"/temp*_label; do
    [[ -f "$tfile" ]] || continue
    if grep -qiE 'tctl|tdie' "$tfile" 2>/dev/null; then
      input_file="${tfile/_label/_input}"
      raw_temp=$(cat "$input_file" 2>/dev/null)
      if [[ "$raw_temp" =~ ^[0-9]+$ ]]; then
        cpu_temp=$(awk "BEGIN { printf \"%.1f\", $raw_temp / 1000 }")
        break 2
      fi
    fi
  done
done

# === Calcular frecuencia promedio ===
freq_avg=$(awk '/cpu MHz/ { sum += $4; n++ } END { if (n > 0) printf "%.0f MHz", sum / n }' /proc/cpuinfo)

# === Mostrar resultados ===
echo "🧠 Procesador: $cpu_model"
echo "- $sockets socket(s)"
echo "- $cores_per_socket núcleo(s) por socket"
echo "- $total_cores núcleos físicos en total"
echo "- $logical_cpus hilos en total (CPU lógicas)"
echo ""
echo "$smt_status"
echo ""

[[ -n "$cpu_temp" ]] && echo "🌡 Temperatura actual del CPU: $cpu_temp °C"
[[ -n "$freq_avg" ]] && echo "⚙ Frecuencia promedio: $freq_avg"
[[ -n "$vcore" ]] && echo "🔋 Voltaje actual del CPU (detectado): $vcore V" || echo "⚠️  No se detectó el voltaje del CPU"
[[ -n "$power_watts" ]] && echo "⚡ Consumo actual del CPU (SVI2 – zenpower): $power_watts W" || echo "⚠️  No se detectó el consumo del CPU"

