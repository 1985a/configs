#!/usr/bin/env bash
# Escribe "Mute: yes" o "Mute: no" según esté silenciada la salida de audio predeterminada.
# conky lo usa para cambiar el color del volumen.
pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null
