#!/usr/bin/env bash
# Rehace los enlaces simbólicos de tu home que apuntan a un disco que cambió de
# punto de montaje.
#
# Uso: actualizar_enlaces.sh RUTA_VIEJA RUTA_NUEVA [CARPETA]
#   ej: actualizar_enlaces.sh /run/media/$USER/DATOS /mnt/datos
# CARPETA es dónde buscar enlaces (por defecto, tu home).
set -euo pipefail

if (( $# < 2 )); then
    echo "Uso: $0 RUTA_VIEJA RUTA_NUEVA [CARPETA]" >&2
    exit 2
fi

old_prefix="${1%/}"
new_prefix="${2%/}"
where="${3:-$HOME}"

# -print0 / read -d '': funciona aunque los nombres tengan espacios o saltos de línea
find "$where" -xdev -type l -lname "$old_prefix/*" -print0 |
while IFS= read -r -d '' lnk; do
    target=$(readlink -- "$lnk")
    new_target="$new_prefix${target#"$old_prefix"}"
    ln -snf -- "$new_target" "$lnk"
    printf 'Actualizado: %s → %s\n' "$lnk" "$new_target"
done
