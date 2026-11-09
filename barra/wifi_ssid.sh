#!/bin/bash
# Nombre de la red wifi a la que está conectada la interfaz (por defecto wifi0)
iw dev "${1:-wifi0}" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p'
