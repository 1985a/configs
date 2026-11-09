#!/usr/bin/env bash
# Dispositivos Bluetooth conectados y su batería, para la barra.
# Llama a "bluetoothctl info" una sola vez por dispositivo conectado
# (antes eran tres llamadas por cada dispositivo emparejado, cada 2 segundos).
set -u

ICON_BT_OFF=$'\xef\x96\xb1'   # nf-mdi-bluetooth_off
ICON_BT_ON=$'\xef\x96\xb0'    # nf-mdi-bluetooth
ICON_BT=$'\xef\x8a\x93'       # nf-fa-bluetooth

if ! systemctl is-active --quiet bluetooth; then
    printf '%s \n' "$ICON_BT_OFF"
    exit 0
fi

output=""
# "bluetoothctl devices Connected" lista solo los conectados (BlueZ ≥ 5.65)
while read -r _ mac _; do
    [[ "$mac" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]] || continue
    info=$(bluetoothctl info "$mac" 2>/dev/null) || continue

    dev_icon=$(awk -F': ' '/^\s*Icon:/ {print $2; exit}' <<< "$info")
    # "Battery Percentage: 0x55 (85)" -> 85
    battery=$(sed -n 's/^\s*Battery Percentage: .*(\([0-9]\+\)).*/\1/p' <<< "$info" | head -n 1)

    case "$dev_icon" in
        input-gaming)   icon="🎮" ;;
        input-keyboard) icon="⌨️" ;;
        input-mouse)    icon="🖱️" ;;
        audio-headset|audio-headphones) icon="🎧" ;;
        *)              icon="🔊" ;;
    esac

    if [[ -n "$battery" ]]; then
        output+="${ICON_BT}${ICON_BT_ON} $icon - Batería: ${battery}%  "
    else
        output+="${ICON_BT}${ICON_BT_ON} $icon - Conectado  "
    fi
done < <(bluetoothctl devices Connected 2>/dev/null)

if [[ -n "$output" ]]; then
    printf '%s\n' "$output"
else
    printf '%s%s x\n' "$ICON_BT_OFF" "$ICON_BT_OFF"
fi
