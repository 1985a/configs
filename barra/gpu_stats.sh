#!/usr/bin/env bash
# Temperatura y consumo de la GPU NVIDIA para la barra.
# Salida: "GPU 54°C 33W"  (si no hay nvidia-smi o falla: "GPU N/A")
set -u

line=$(nvidia-smi --query-gpu=temperature.gpu,power.draw \
    --format=csv,noheader,nounits 2>/dev/null | head -n 1)

IFS=', ' read -r temp watts _ <<< "$line"

if [[ -z "${temp:-}" || -z "${watts:-}" ]]; then
    printf 'GPU N/A'
    exit 0
fi

printf 'GPU %s°C %sW' "$temp" "$watts"
