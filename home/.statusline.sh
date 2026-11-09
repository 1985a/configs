#!/bin/sh
# Línea de estado sencilla: carga del sistema y hora, o una notificación si se pasa
# un texto como argumento.
if [ $# -eq 0 ]; then
    read -r l1 l5 l15 _ < /proc/loadavg
    echo "[load $l1 $l5 $l15]   $(date +'%R')"
else
    echo "NOTIFICATION: $1"
fi
