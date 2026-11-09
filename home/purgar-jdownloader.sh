#!/usr/bin/env bash
# Desinstala JDownloader por completo: procesos, servicio, paquete, archivos del
# sistema y TODO archivo de tu home cuyo nombre contenga "jdownloader".
# Uso: purgar-jdownloader.sh   (pide confirmación; con -y no pregunta)

set -u

if [[ "${1:-}" != "-y" ]]; then
    read -rp "Esto borra JDownloader y cualquier archivo *jdownloader* de $HOME. ¿Seguir? [s/N] " ok
    [[ "$ok" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

log() {
    printf '%s\n' "$*"
}

remove_path() {
    local p="$1"

    if [ -e "$p" ] || [ -L "$p" ]; then
        log "Borrando: $p"
        sudo rm -rf -- "$p" 2>/dev/null || rm -rf -- "$p" 2>/dev/null || true
    fi
}

remove_user_path() {
    local p="$1"

    if [ -e "$p" ] || [ -L "$p" ]; then
        log "Borrando: $p"
        rm -rf -- "$p" 2>/dev/null || true
    fi
}

log "==> Cerrando procesos..."
pkill -f -i jdownloader 2>/dev/null || true
pkill -f 'JDownloader.jar' 2>/dev/null || true
pkill -f '/opt/JDownloader' 2>/dev/null || true

log "==> Deteniendo servicio si existe..."
sudo systemctl stop jdownloader.service 2>/dev/null || true
sudo systemctl disable jdownloader.service 2>/dev/null || true

log "==> Eliminando paquete si existe..."
if command -v pacman >/dev/null 2>&1; then
    sudo pacman -Rns --noconfirm jdownloader2 2>/dev/null || true
    sudo pacman -Rns --noconfirm jdownloader2-latest 2>/dev/null || true
fi

log "==> Eliminando archivos del sistema..."
system_paths=(
    "/usr/share/icons/hicolor/48x48/apps/jdownloader.png"
    "/usr/share/icons/hicolor/22x22/apps/jdownloader.png"
    "/usr/share/icons/hicolor/32x32/apps/jdownloader.png"
    "/usr/share/icons/hicolor/16x16/apps/jdownloader.png"
    "/usr/share/icons/hicolor/24x24/apps/jdownloader.png"
    "/usr/share/icons/hicolor/256x256/apps/jdownloader.png"
    "/usr/share/applications/jdownloader.desktop"
    "/usr/share/mime/packages/jdownloader.xml"
    "/usr/bin/JDownloaderHeadLessCtl"
    "/usr/bin/JDownloaderHeadless"
    "/usr/bin/jdownloader"
    "/usr/bin/JDownloaderHeadlessCleanLogin"
    "/usr/bin/JDownloader"
    "/usr/lib/systemd/system/jdownloader.service"
    "/opt/JDownloaderScripts"
    "/opt/JDownloader"
    "/etc/firejail/JDownloader.profile"
    "/etc/firejail/jdownloader.profile"
)

for p in "${system_paths[@]}"; do
    remove_path "$p"
done

log "==> Eliminando restos del usuario..."
user_paths=(
    "$HOME/.jd"
    "$HOME/.jdownloader"
    "$HOME/.config/jdownloader"
    "$HOME/.config/JDownloader"
    "$HOME/.local/share/JDownloader"
    "$HOME/.cache/JDownloader"
    "$HOME/.cache/jdownloader"
    "$HOME/.cache/yay/jdownloader2"
    "$HOME/.local/bin/JDownloader"
    "$HOME/.local/bin/jdownloader"
    "$HOME/.local/share/applications/jdownloader.desktop"
    "$HOME/.local/share/icons/Slot-Spectrum-Light-Icons/apps/48/org.jdownloader.JDownloader.svg"
    "$HOME/.local/share/icons/Slot-Spectrum-Light-Icons/apps/48/jdownloader-beta.svg"
    "$HOME/.local/share/icons/Slot-Spectrum-Light-Icons/apps/48/jdownloader.svg"
    "$HOME/.icons/la-capitaine-icon-theme-0.6.2/apps/scalable/jdownloader.svg"
)

for p in "${user_paths[@]}"; do
    remove_user_path "$p"
done

log "==> Buscando y eliminando coincidencias adicionales dentro de HOME..."
find "$HOME" \( -iname '*jdownloader*' -o -iname 'JDownloader.jar' \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
    log "Borrando encontrado: $f"
    rm -rf -- "$f" 2>/dev/null || true
done

log "==> Regenerando cachés si las herramientas existen..."
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    sudo update-desktop-database /usr/share/applications 2>/dev/null || true
fi

hash -r 2>/dev/null || true

log ""
log "Proceso terminado."
log "Ahora verifica con:"
log "find /usr /opt /etc /var \"\$HOME\" \\( -iname '*jdownloader*' -o -iname 'JDownloader.jar' \\) 2>/dev/null"
