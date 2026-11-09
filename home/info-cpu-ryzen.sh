#!/bin/bash
# info-cpu-ryzen.sh — Información del CPU para la familia AMD Ryzen (Zen 1 a Zen 5)
#
# Fuentes de datos:
#   Temperatura: k10temp (Tctl/Tdie/Tccd) o zenpower
#   Consumo:     RAPL (powercap o MSR 0xC001029B paquete / 0xC001029A por núcleo)
#                zenpower: SVI2 núcleo + SoC (Zen 1–3)
#   Voltaje:     zenpower SVI2 (real, Zen 1–3) > sensor de la placa > VID del MSR (solicitado)
#
# Ejecutar como root (MSR y RAPL solo son legibles por root).

INTERVALO=1   # segundos para medir el consumo

[[ $EUID -ne 0 ]] && echo "⚠️  Ejecuta como root (sudo $0) para leer consumo y voltaje."
grep -q AuthenticAMD /proc/cpuinfo || echo "⚠️  Este CPU no es AMD; el script está pensado para Ryzen."

# ---------- utilidades ----------
a_decimal() { awk "BEGIN{printf \"%.${2:-2}f\", $1}"; }

leer_msr() {   # $1 = cpu, $2 = dirección (hex) -> valor decimal
  local raw
  [[ -r /dev/cpu/$1/msr ]] || return 1
  raw=$(dd if=/dev/cpu/$1/msr bs=8 count=1 skip=$(( $2 )) iflag=skip_bytes 2>/dev/null | od -An -t u8 | tr -d ' ')
  [[ "$raw" =~ ^[0-9]+$ ]] && echo "$raw"
}

hwmon_por_nombre() {   # devuelve el directorio hwmon con ese nombre
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [[ "$(cat "$d/name" 2>/dev/null)" == "$1" ]] && { echo "$d"; return 0; }
  done
  return 1
}

leer_etiqueta() {   # $1 = dir hwmon, $2 = prefijo (temp|in|power), $3 = regex de etiqueta -> valor crudo
  local f raw
  for f in "$1"/$2*_label; do
    [[ -f "$f" ]] || continue
    if grep -qiE "$3" "$f"; then
      raw=$(cat "${f/_label/_input}" 2>/dev/null)
      [[ "$raw" =~ ^-?[0-9]+$ ]] && { echo "$raw"; return 0; }
    fi
  done
  return 1
}

[[ -e /dev/cpu/0/msr ]] || modprobe msr 2>/dev/null

# ---------- identificación ----------
cpu_model=$(lscpu | awk -F: '/^Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
familia=$(awk '/^cpu family/ {print $4; exit}' /proc/cpuinfo)
modelo=$(awk '/^model[ \t]*:/ {print $3; exit}' /proc/cpuinfo)

case "$familia" in
  23) generacion="Zen / Zen+ / Zen 2 (Ryzen 1000–4000)" ; svi=2 ;;
  25) if (( (modelo >= 0x10 && modelo <= 0x1F) || (modelo >= 0x60 && modelo <= 0xAF) )); then
        generacion="Zen 4 (Ryzen 7000/8000)" ; svi=3
      else
        generacion="Zen 3 (Ryzen 5000)" ; svi=2
      fi ;;
  26) generacion="Zen 5 (Ryzen 9000)" ; svi=3 ;;
  *)  generacion="desconocida (familia $familia)" ; svi=0 ;;
esac

sockets=$(lscpu -p=SOCKET | grep -v '^#' | sort -u | wc -l)
total_cores=$(lscpu -p=SOCKET,CORE | grep -v '^#' | sort -u | wc -l)
logical_cpus=$(nproc --all)
num_ccx=$(cat /sys/devices/system/cpu/cpu[0-9]*/cache/index3/shared_cpu_list 2>/dev/null | sort -u | wc -l)

smt_activo=0
[[ -r /sys/devices/system/cpu/smt/active ]] && smt_activo=$(cat /sys/devices/system/cpu/smt/active)
(( logical_cpus > total_cores )) && smt_activo=1

# Una CPU lógica por núcleo físico (para leer energía por núcleo)
mapfile -t cpus_nucleo < <(lscpu -p=CPU,CORE | grep -v '^#' | sort -t, -k2,2n -k1,1n | awk -F, '!v[$2]++ {print $1}')

zp=$(hwmon_por_nombre zenpower)
k10=$(hwmon_por_nombre k10temp)

# ---------- temperatura ----------
temp_tipo="" ; cpu_temp=""
for dir in $zp $k10; do
  if raw=$(leer_etiqueta "$dir" temp '^tdie'); then temp_tipo="Tdie"; cpu_temp=$(a_decimal "$raw/1000" 1); break; fi
done
if [[ -z "$cpu_temp" ]]; then
  for dir in $zp $k10; do
    if raw=$(leer_etiqueta "$dir" temp '^tctl'); then temp_tipo="Tctl"; cpu_temp=$(a_decimal "$raw/1000" 1); break; fi
  done
fi

temps_ccd=""
for dir in $k10 $zp; do
  for f in "$dir"/temp*_label; do
    [[ -f "$f" ]] || continue
    lbl=$(cat "$f")
    if [[ "$lbl" =~ ^Tccd ]]; then
      raw=$(cat "${f/_label/_input}" 2>/dev/null)
      [[ "$raw" =~ ^[0-9]+$ ]] && temps_ccd+="${lbl/Tccd/CCD}: $(a_decimal "$raw/1000" 1) °C   "
    fi
  done
  [[ -n "$temps_ccd" ]] && break
done

# ---------- frecuencia ----------
freq_info=$(awk '{s+=$1; n++; if($1>m)m=$1} END{if(n) printf "%.0f MHz (máx. %.0f MHz)", s/n/1000, m/1000}' \
  /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null)
[[ -z "$freq_info" ]] && freq_info=$(awk '/cpu MHz/{s+=$4;n++} END{if(n) printf "%.0f MHz", s/n}' /proc/cpuinfo)
driver_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)

# ---------- voltaje ----------
vcore="" ; vsoc="" ; v_fuente=""
if [[ -n "$zp" ]]; then
  raw=$(leer_etiqueta "$zp" in 'svi2_core') && vcore=$(a_decimal "$raw/1000" 3)
  raw=$(leer_etiqueta "$zp" in 'svi2_soc')  && vsoc=$(a_decimal "$raw/1000" 3)
  [[ -n "$vcore" ]] && v_fuente="SVI2 – zenpower, real"
fi

if [[ -z "$vcore" ]]; then   # sensores de la placa con etiqueta
  for f in /sys/class/hwmon/hwmon*/in*_label; do
    [[ -f "$f" ]] || continue
    if grep -qiE 'vcore|cpu vdd|vddcr_cpu' "$f"; then
      raw=$(cat "${f/_label/_input}" 2>/dev/null)
      [[ "$raw" =~ ^[0-9]+$ ]] && { vcore=$(a_decimal "$raw/1000" 3); v_fuente="sensor de la placa"; break; }
    fi
  done
fi

# VID solicitado: MSR 0xC0010293 (P-state status), CpuVid bits 21:14, V = 1.55 - VID*0.00625
vid_max="" ; vid_min=""
if (( svi == 2 )); then
  for c in "${cpus_nucleo[@]}"; do
    raw=$(leer_msr "$c" 0xC0010293) || continue
    vid=$(( (raw >> 14) & 0xFF ))
    v=$(a_decimal "1.55 - $vid*0.00625" 3)
    if awk "BEGIN{exit !($v > 0.2 && $v < 1.6)}"; then
      [[ -z "$vid_max" ]] || awk "BEGIN{exit !($v > $vid_max)}" && vid_max=$v
      [[ -z "$vid_min" ]] || awk "BEGIN{exit !($v < $vid_min)}" && vid_min=$v
    fi
  done
fi

# ---------- consumo ----------
# Unidad de energía RAPL de AMD: MSR 0xC0010299 bits 12:8 -> 1 / 2^ESU julios
unidad_j=""
if raw=$(leer_msr 0 0xC0010299); then
  esu=$(( (raw >> 8) & 0x1F ))
  unidad_j=$(a_decimal "1/(2^$esu)" 12)
fi

# Dominio de paquete en powercap (kernel 5.8+ también para AMD)
pkg_dom=""
for d in /sys/class/powercap/intel-rapl:[0-9]; do
  [[ "$(cat "$d/name" 2>/dev/null)" == package-0 ]] && pkg_dom=$d && break
done

# Lecturas iniciales
pc1="" ; pm1="" ; declare -A ec1
[[ -n "$pkg_dom" ]] && pc1=$(cat "$pkg_dom/energy_uj" 2>/dev/null)
if [[ -n "$unidad_j" ]]; then
  pm1=$(leer_msr 0 0xC001029B)
  for c in "${cpus_nucleo[@]}"; do ec1[$c]=$(leer_msr "$c" 0xC001029A); done
fi

hay_muestra=0
[[ -n "$pc1" || -n "$pm1" || ${#ec1[@]} -gt 0 ]] && { sleep "$INTERVALO"; hay_muestra=1; }

delta32() {   # contadores MSR de 32 bits con vuelta
  local d=$(( ($2 & 0xFFFFFFFF) - ($1 & 0xFFFFFFFF) ))
  (( d < 0 )) && d=$(( d + 4294967296 ))
  echo "$d"
}

power_pkg="" ; pkg_fuente=""
if (( hay_muestra )); then
  if [[ -n "$pc1" ]]; then
    pc2=$(cat "$pkg_dom/energy_uj" 2>/dev/null)
    max=$(cat "$pkg_dom/max_energy_range_uj" 2>/dev/null || echo 0)
    d=$(( pc2 - pc1 )); (( d < 0 )) && d=$(( d + max ))
    power_pkg=$(a_decimal "$d/($INTERVALO*1000000)") ; pkg_fuente="RAPL powercap"
  elif [[ -n "$pm1" ]]; then
    pm2=$(leer_msr 0 0xC001029B)
    power_pkg=$(a_decimal "$(delta32 "$pm1" "$pm2")*$unidad_j/$INTERVALO") ; pkg_fuente="RAPL MSR"
  fi
fi

power_cores="" ; detalle_cores=""
if (( hay_muestra )) && [[ ${#ec1[@]} -gt 0 ]]; then
  total=0 ; i=0
  for c in "${cpus_nucleo[@]}"; do
    [[ -n "${ec1[$c]}" ]] || continue
    e2=$(leer_msr "$c" 0xC001029A) || continue
    w=$(a_decimal "$(delta32 "${ec1[$c]}" "$e2")*$unidad_j/$INTERVALO")
    total=$(a_decimal "$total + $w")
    detalle_cores+=$(printf "N%-2d %6s W   " "$i" "$w")
    (( ++i % 4 == 0 )) && detalle_cores+=$'\n'
  done
  (( i > 0 )) && power_cores=$total
fi

svi_core_w="" ; svi_soc_w=""
if [[ -n "$zp" ]]; then
  raw=$(leer_etiqueta "$zp" power 'svi2_p_core') && svi_core_w=$(a_decimal "$raw/1000000")
  raw=$(leer_etiqueta "$zp" power 'svi2_p_soc')  && svi_soc_w=$(a_decimal "$raw/1000000")
fi

# ---------- resultados ----------
echo "🧠 Procesador: $cpu_model"
echo "- Arquitectura: $generacion"
echo "- $sockets socket(s), $total_cores núcleos físicos, $logical_cpus hilos"
(( num_ccx > 0 )) && echo "- $num_ccx grupo(s) de caché L3 (CCX)"
echo ""
[[ $smt_activo -eq 1 ]] && echo "🟢 SMT está ACTIVADO" || echo "🔴 SMT está DESACTIVADO"
echo ""

if [[ -n "$cpu_temp" ]]; then
  echo "🌡  Temperatura ($temp_tipo): $cpu_temp °C"
  [[ "$temp_tipo" == Tctl && "$familia" == 23 ]] && echo "   (en Ryzen 1000/2000 serie X, Tctl puede tener un offset de +10/+20 °C)"
  [[ -n "$temps_ccd" ]] && echo "   └ $temps_ccd"
else
  echo "⚠️  No se detectó la temperatura (¿módulo k10temp cargado?)"
fi

echo "⚙  Frecuencia promedio: $freq_info${driver_freq:+  [driver: $driver_freq]}"

if [[ -n "$vcore" ]]; then
  echo "🔋 Voltaje del núcleo ($v_fuente): $vcore V"
  [[ -n "$vsoc" ]] && echo "🔋 Voltaje SoC: $vsoc V"
fi
if [[ -n "$vid_max" ]]; then
  if [[ "$vid_min" == "$vid_max" ]]; then
    echo "🔋 VID solicitado por los núcleos: $vid_max V"
  else
    echo "🔋 VID solicitado por los núcleos: $vid_min – $vid_max V"
  fi
fi
if [[ -z "$vcore" && -z "$vid_max" ]]; then
  if (( svi == 3 )); then
    echo "⚠️  Voltaje no disponible: Zen 4/5 usa SVI3 y Linux aún no lo expone de forma fiable"
  else
    echo "⚠️  No se detectó el voltaje (¿root? ¿módulo msr? instala zenpower para SVI2)"
  fi
fi

if [[ -n "$power_pkg" ]]; then
  echo "⚡ Consumo del paquete ($pkg_fuente): $power_pkg W"
fi
if [[ -n "$power_cores" ]]; then
  echo "⚡ Consumo de los núcleos (suma RAPL): $power_cores W"
  echo "$detalle_cores" | sed '/^$/d; s/^/   /'
fi
if [[ -n "$svi_core_w" ]]; then
  echo "⚡ SVI2 – zenpower: núcleo $svi_core_w W${svi_soc_w:+, SoC $svi_soc_w W}"
fi
if [[ -z "$power_pkg" && -z "$power_cores" && -z "$svi_core_w" ]]; then
  echo "⚠️  No se detectó el consumo (¿root? ¿módulo msr cargado?)"
fi
