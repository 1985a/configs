#!/usr/bin/env bash
set -euo pipefail

# gpu-monitor.sh — Monitor de GPU NVIDIA en consola usando nvidia-smi
#
# Uso:
#   ./gpu-monitor.sh              # refresca cada 1s
#   ./gpu-monitor.sh -i 2         # refresca cada 2s
#   ./gpu-monitor.sh -g 0         # solo GPU 0
#   ./gpu-monitor.sh -i 1 -g 1    # GPU 1, cada 1s
#
# Salir: Ctrl+C

interval=1
gpu_index="all"

usage() {
  cat <<'EOF'
Uso: gpu-monitor.sh [-i SEGUNDOS] [-g GPU_INDEX]

  -i SEGUNDOS   Intervalo de refresco (default: 1)
  -g GPU_INDEX  GPU específica (0,1,2...). Default: todas
  -h            Ayuda

Requiere: nvidia-smi (driver NVIDIA instalado)
EOF
}

while getopts ":i:g:h" opt; do
  case "$opt" in
    i) interval="$OPTARG" ;;
    g) gpu_index="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "Error: nvidia-smi no está disponible. ¿Tienes instalado el driver NVIDIA?" >&2
  exit 1
fi

if ! [[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Error: intervalo inválido: $interval" >&2
  exit 2
fi

query_fields="index,name,temperature.gpu,fan.speed,power.draw,pstate,clocks.gr,clocks.mem,memory.used,memory.total"
format="csv,noheader,nounits"

run_query() {
  if [[ "$gpu_index" == "all" ]]; then
    nvidia-smi --query-gpu="$query_fields" --format="$format" 2>/dev/null || true
  else
    nvidia-smi -i "$gpu_index" --query-gpu="$query_fields" --format="$format" 2>/dev/null || true
  fi
}

print_header() {
  printf "%-3s  %-28s  %6s  %6s  %7s  %6s  %7s  %7s  %12s\n" \
    "GPU" "NAME" "TEMP" "FAN" "PWR" "PSTATE" "CLK_GR" "CLK_MEM" "MEM"
  printf "%s\n" "-----------------------------------------------------------------------------------------------"
}

print_rows() {
  local line
  while IFS= read -r line; do
    # line example:
    # 0, NVIDIA GeForce RTX 3080 Ti, 52, 41, 120.34, P2, 1500, 9501, 1234, 12288
    # Parse por comas (con espacios)
    IFS=',' read -r idx name temp fan pwr pst clkgr clkmem memu memt <<<"$line"

    # Trim espacios
    idx="${idx// /}"
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
    temp="${temp// /}"
    fan="${fan// /}"
    pwr="${pwr// /}"
    pst="${pst// /}"
    clkgr="${clkgr// /}"
    clkmem="${clkmem// /}"
    memu="${memu// /}"
    memt="${memt// /}"

    # Algunos campos pueden venir vacíos si el driver no reporta
    [[ -z "$fan" ]] && fan="N/A"
    [[ -z "$pwr" ]] && pwr="N/A"

    printf "%-3s  %-28.28s  %4s°C  %4s%%  %6sW  %6s  %6sMHz  %6sMHz  %5s/%-5s MiB\n" \
      "$idx" "$name" "$temp" "$fan" "$pwr" "$pst" "$clkgr" "$clkmem" "$memu" "$memt"
  done
}

trap 'printf "\nSaliendo...\n"; exit 0' INT

while true; do
  clear
  printf "GPU Monitor (nvidia-smi) | intervalo: %ss | %s | %s\n" \
    "$interval" \
    "$(date '+%Y-%m-%d %H:%M:%S')" \
    "Ctrl+C para salir"
  echo

  out="$(run_query)"
  if [[ -z "$out" ]]; then
    echo "No pude obtener datos de nvidia-smi. ¿La GPU está disponible?"
  else
    print_header
    printf "%s\n" "$out" | print_rows
  fi

  sleep "$interval"
done

