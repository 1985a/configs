#!/bin/bash

# Directorio donde se guardarán las capturas de pantalla
SCREENSHOT_DIR="$HOME/Pictures/Screenshots"

# Crear el directorio si no existe
[ ! -d "$SCREENSHOT_DIR" ] && mkdir -p "$SCREENSHOT_DIR"

# Nombre del archivo de la captura de pantalla
FILENAME="screenshot-$(date +'%Y%m%d%H%M%S').png"
FILEPATH="$SCREENSHOT_DIR/$FILENAME"

# Capturar pantalla completa o una región seleccionada
if [ "$1" == "full" ]; then
    grim "$FILEPATH" && notify-send "Captura de pantalla" "Pantalla completa guardada en $FILEPATH"
else
    grim -g "$(slurp)" "$FILEPATH" && notify-send "Captura de pantalla" "Región guardada en $FILEPATH"
fi
