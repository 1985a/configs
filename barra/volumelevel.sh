#!/usr/bin/env bash
# Volumen de la salida de audio predeterminada, con icono de altavoz para la barra.
# Antes leía "pactl list sinks" y tomaba la primera salida, que no tiene por qué ser
# la predeterminada; ahora pregunta directamente por @DEFAULT_SINK@.
set -u

ICON_MUTED=$'\xef\x80\xa6'   # nf-fa-volume_off
ICON_ON=$'\xef\x80\xa8'      # nf-fa-volume_up

vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -o '[0-9]\+%' | head -n 1 | tr -d '%')
mute=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')

if [[ "$mute" == "yes" ]]; then
    printf '%s  %s\n' "$ICON_MUTED" "${vol:-0}"
else
    printf '%s  %s\n' "$ICON_ON" "${vol:-0}"
fi
