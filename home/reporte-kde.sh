#!/usr/bin/env bash
set -u

INPUT="/tmp/kde-candidatos.txt"
OUT="$HOME/reporte-kde-dependencias.txt"

if [[ ! -f "$INPUT" ]]; then
    echo "No existe $INPUT"
    echo "Primero genera la lista de candidatos KDE en /tmp/kde-candidatos.txt"
    exit 1
fi

{
    echo "REPORTE DE LIMPIEZA KDE/PLASMA - ARCH LINUX"
    echo "Generado: $(date)"
    echo "Usuario: $USER"
    echo "Host: $(hostname)"
    echo

    echo "============================================================"
    echo "1. PAQUETES CANDIDATOS KDE/PLASMA"
    echo "============================================================"
    cat "$INPUT"
    echo

    echo "============================================================"
    echo "2. DEPENDENCIAS INVERSAS POR PAQUETE"
    echo "============================================================"

    while read -r pkg; do
        [[ -z "$pkg" ]] && continue

        echo
        echo "------------------------------------------------------------"
        echo "PAQUETE: $pkg"
        echo "------------------------------------------------------------"

        if ! pacman -Q "$pkg" &>/dev/null; then
            echo "Estado: NO instalado actualmente"
            continue
        fi

        echo "Info pacman:"
        pacman -Qi "$pkg" 2>/dev/null | sed 's/^/  /'
        echo

        echo "Dependencias inversas con pactree -r:"
        if command -v pactree &>/dev/null; then
            pactree -r "$pkg" 2>/dev/null | sed 's/^/  /'
        else
            echo "  pactree no está instalado. Instala pacman-contrib."
        fi

        echo
        echo "Paquetes que requieren directamente a $pkg:"
        pacman -Qi "$pkg" 2>/dev/null | awk -F: '/Required By/ {print $2}' | sed 's/^/  /'

    done < "$INPUT"

    echo
    echo "============================================================"
    echo "3. PAQUETES INSTALADOS QUE CONTIENEN KDE/PLASMA/KWIN"
    echo "============================================================"
    pacman -Qq | grep -Ei '^(ark|baloo|baloo-widgets|dolphin|dolphin-plugins|gwenview|kactivities|kactivities5|kactivities-stats5|kde-|kdebugsettings|kdeclarative|kdeclarative5|kdeconnect|kded|kded5|kdeedu-data|kdegraphics-|kdenetwork-|kdenlive|kdepim-|kdesdk-|kdesu|kdesu5|kdevelop|kdevelop-|kglobalaccel|kglobalaccel5|konsole|kwayland|kwayland5|kwindowsystem|kwindowsystem5|oxygen-icons|plasma-framework5)$' || true

    echo
    echo "============================================================"
    echo "4. AUTOSTART KDE/PLASMA"
    echo "============================================================"
    find /etc/xdg/autostart "$HOME/.config/autostart" \
        \( -iname '*kde*' -o -iname '*plasma*' -o -iname '*kwin*' -o -iname '*baloo*' -o -iname '*kglobalaccel*' \) \
        2>/dev/null | sort || true

    echo
    echo "============================================================"
    echo "5. PROPIETARIO PACMAN DE AUTOSTART KDE/PLASMA"
    echo "============================================================"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo
        echo "Archivo: $f"
        pacman -Qo "$f" 2>/dev/null || echo "No pertenece a ningún paquete"
    done < <(
        find /etc/xdg/autostart "$HOME/.config/autostart" \
            \( -iname '*kde*' -o -iname '*plasma*' -o -iname '*kwin*' -o -iname '*baloo*' -o -iname '*kglobalaccel*' \) \
            2>/dev/null | sort
    )

    echo
    echo "============================================================"
    echo "6. SERVICIOS DBUS KDE/PLASMA"
    echo "============================================================"
    find /usr/share/dbus-1/services /usr/share/dbus-1/session.d /usr/share/dbus-1/system.d \
        \( -iname '*kde*' -o -iname '*plasma*' -o -iname '*kwin*' -o -iname '*dolphin*' -o -iname '*kded*' \) \
        2>/dev/null | sort || true

    echo
    echo "============================================================"
    echo "7. PROPIETARIO PACMAN DE SERVICIOS DBUS KDE/PLASMA"
    echo "============================================================"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo
        echo "Archivo: $f"
        pacman -Qo "$f" 2>/dev/null || echo "No pertenece a ningún paquete"
    done < <(
        find /usr/share/dbus-1/services /usr/share/dbus-1/session.d /usr/share/dbus-1/system.d \
            \( -iname '*kde*' -o -iname '*plasma*' -o -iname '*kwin*' -o -iname '*dolphin*' -o -iname '*kded*' \) \
            2>/dev/null | sort
    )

    echo
    echo "============================================================"
    echo "8. SYSTEMD USER KDE/PLASMA"
    echo "============================================================"
    systemctl --user list-unit-files | grep -Ei 'kde|plasma|kwin|dolphin|baloo|kded|kglobalaccel' || true

    echo
    echo "============================================================"
    echo "9. JOURNAL USER ACTUAL KDE/PLASMA"
    echo "============================================================"
    journalctl --user -b --no-pager | grep -Ei 'kde|plasma|kwin|dolphin|kded|baloo|kglobalaccel' | tail -120 || true

    echo
    echo "============================================================"
    echo "10. FUENTES ACTUALES"
    echo "============================================================"
    echo "sans:"
    fc-match sans || true
    echo "serif:"
    fc-match serif || true
    echo "monospace:"
    fc-match monospace || true
    echo "emoji:"
    fc-match emoji || true

    echo
    echo "============================================================"
    echo "11. HUÉRFANOS ACTUALES"
    echo "============================================================"
    pacman -Qdtq 2>/dev/null || true

} > "$OUT"

echo "Reporte generado en:"
echo "$OUT"
echo
echo "Puedes subir ese archivo aquí."
