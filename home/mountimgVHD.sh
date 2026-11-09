#!/usr/bin/env bash
# Monta una imagen de disco VHD (Virtual PC / Hyper-V) con qemu-nbd y, si se indica,
# copia su contenido a una carpeta. Al terminar desmonta y libera /dev/nbd0.
#
# Uso: mountimgVHD.sh IMAGEN.vhd [CARPETA_DESTINO]
#   Sin destino, deja la imagen montada en /mnt/vhd y te dice cómo desmontarla.
#   La imagen también puede venir de VHD_IMAGE en ~/.config/home-scripts.env.
# Antes copiaba a "/ruta/de/destino/" (un marcador sin rellenar) y la imagen estaba
# fija en el script.
set -euo pipefail

# shellcheck disable=SC1091
[[ -r "$HOME/.config/home-scripts.env" ]] && . "$HOME/.config/home-scripts.env"

IMG="${1:-${VHD_IMAGE:-}}"
DEST="${2:-}"
NBD=/dev/nbd0
MNT=/mnt/vhd

if [[ -z "$IMG" || ! -f "$IMG" ]]; then
    echo "Uso: $0 IMAGEN.vhd [CARPETA_DESTINO]" >&2
    exit 2
fi

sudo modprobe nbd max_part=8
sudo qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
sudo qemu-nbd --format=vpc -c "$NBD" "$IMG"
sleep 1   # deja que el kernel lea la tabla de particiones
lsblk "$NBD"

sudo mkdir -p "$MNT"
sudo mount -o "uid=$(id -u),gid=$(id -g),umask=022" "${NBD}p1" "$MNT"

if [[ -z "$DEST" ]]; then
    echo "Montada en $MNT. Para desmontar:  sudo umount $MNT && sudo qemu-nbd -d $NBD"
    exit 0
fi

# desmonta pase lo que pase con la copia
trap 'sudo umount "$MNT"; sudo qemu-nbd -d "$NBD" >/dev/null' EXIT
mkdir -p "$DEST"
cp -r "$MNT"/. "$DEST"/
echo "Copiado en $DEST"
