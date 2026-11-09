#!/usr/bin/env bash
# Instala estas configuraciones en tu home.
#
#   ./install.sh              enlaces simbólicos al repositorio (recomendado: lo que
#                             cambies en tu sistema queda listo para hacer commit)
#   ./install.sh --copy       copias en lugar de enlaces
#   ./install.sh --dry-run    solo muestra lo que haría
#
# Todo archivo que ya exista y sea distinto se guarda antes en
#   ~/.local/state/configs-backup/FECHA/   (con la misma ruta relativa a tu home)
# así que se puede volver atrás copiando de ahí.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MODE="link"
DRY=0

for arg in "$@"; do
    case "$arg" in
        --copy)    MODE="copy" ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
    esac
done

BACKUP="$HOME/.local/state/configs-backup/$(date +%Y%m%d-%H%M%S)"
changed=0

run() {
    if (( DRY )); then echo "   [dry-run] $*"; else "$@"; fi
}

# install_file ORIGEN_EN_REPO DESTINO_RELATIVO_A_HOME
install_file() {
    local src="$REPO/$1" dst="$HOME/$2"

    # ya instalado: el enlace apunta aquí o la copia es idéntica
    if [[ "$MODE" == "link" && -L "$dst" && "$(readlink -f "$dst")" == "$src" ]]; then
        return
    fi
    if [[ "$MODE" == "copy" && -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
        return
    fi

    if [[ -e "$dst" || -L "$dst" ]]; then
        run mkdir -p "$(dirname "$BACKUP/$2")"
        run mv -- "$dst" "$BACKUP/$2"
        echo "📦 respaldo: ~/$2"
    fi

    run mkdir -p "$(dirname "$dst")"
    if [[ "$MODE" == "link" ]]; then
        run ln -s -- "$src" "$dst"
    else
        run cp -p -- "$src" "$dst"
    fi
    echo "✅ ~/$2"
    changed=$((changed + 1))
}

# instala todos los archivos de una carpeta del repo en una carpeta de home
install_dir() {
    local srcdir="$1" dstdir="$2" f
    while IFS= read -r -d '' f; do
        if [[ "$dstdir" == "." ]]; then
            install_file "$srcdir/${f##*/}" "${f##*/}"
        else
            install_file "$srcdir/${f##*/}" "$dstdir/${f##*/}"
        fi
    done < <(find "$REPO/$srcdir" -maxdepth 1 -type f -print0 | sort -z)
}

echo "Instalando desde $REPO (modo: $MODE)"

# sway (lee ~/.config/i3/config si no hay ~/.config/sway/config)
install_file sway/config              .config/i3/config
install_file sway/screenshot.sh       .config/i3/screenshot.sh

# barra de estado: conky + scripts
install_file conky/conkyrc.json       .conkyrc.json
install_file conky/conky-wrapper      conky-wrapper
install_dir  barra                    .scripts/scripts
install_file x11/dir_colors           .scripts/dir_colors
install_file x11/Xresources           .Xresources

# música
install_file mpd/mpd.conf             .mpd/mpd.conf
install_dir  ncmpcpp                  .ncmpcpp
install_dir  bin                      .local/bin

# escritorio y terminal
install_file mako/config              .config/mako/config
install_file mako/restart.conf        .config/systemd/user/mako.service.d/restart.conf
install_file kitty/kitty.conf         .config/kitty/kitty.conf
install_file rofi/config.rasi         .config/rofi/config.rasi
install_file tmux/tmux.conf           .tmux.conf
install_dir  fonts                    .local/share/fonts

# shells
install_file zsh/zshrc                .zshrc
install_file zsh/zprofile             .zprofile
install_file zsh/zshenv               .zshenv
install_file shell/profile            .profile
install_file shell/bash_profile       .bash_profile
install_file shell/bashrc             .bashrc

# git: nombre y correo quedan en ~/.gitconfig.local (fuera del repo)
if [[ ! -e "$HOME/.gitconfig.local" && -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]; then
    name=$(git config -f "$HOME/.gitconfig" user.name || true)
    email=$(git config -f "$HOME/.gitconfig" user.email || true)
    if [[ -n "$name$email" ]]; then
        echo "✅ ~/.gitconfig.local (con tu nombre y correo del ~/.gitconfig anterior)"
        if (( ! DRY )); then
            [[ -n "$name"  ]] && git config -f "$HOME/.gitconfig.local" user.name "$name"
            [[ -n "$email" ]] && git config -f "$HOME/.gitconfig.local" user.email "$email"
            # conserva también los safe.directory de esta máquina
            git config -f "$HOME/.gitconfig" --get-all safe.directory 2>/dev/null | sort -u |
                while IFS= read -r d; do git config -f "$HOME/.gitconfig.local" --add safe.directory "$d"; done
        fi
    fi
fi
install_file git/gitconfig            .gitconfig

# scripts de la raíz de tu home (incluye los ocultos: .vocab, .statusline.sh...)
install_dir  home                     .

# servicios systemd del usuario
install_dir  systemd/user             .config/systemd/user

# carpetas que mpd necesita
run mkdir -p "$HOME/.mpd/playlists" "$HOME/.mpd/cache"

if (( ! DRY )); then
    fc-cache -f "$HOME/.local/share/fonts" >/dev/null 2>&1 || true
    # solo si se instala en el home real del usuario (no en una prueba con HOME=otro)
    if [[ "$HOME" == "$(getent passwd "$(id -un)" | cut -d: -f6)" ]] \
        && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user daemon-reload
        systemctl --user enable --now archnews-check.timer >/dev/null 2>&1 \
            && echo "✅ temporizador archnews-check activado"
    fi
fi

echo
if (( changed == 0 )); then
    echo "Nada que cambiar: todo estaba instalado."
elif (( ! DRY )) && [[ -d "$BACKUP" ]]; then
    echo "Archivos anteriores guardados en: $BACKUP"
fi

# valores privados que no viajan en el repositorio
cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
[[ -e "$cfg/zsh/local.zsh" ]]         || echo "ℹ️  Crea $cfg/zsh/local.zsh a partir de local.example/zsh-local.zsh"
[[ -e "$cfg/weather-location" ]]      || echo "ℹ️  Escribe tu ciudad en $cfg/weather-location (ver local.example/)"
[[ -e "$cfg/home-scripts.env" ]]      || echo "ℹ️  Si usas los scripts de red: copia local.example/home-scripts.env a $cfg/"
echo "Recarga sway con Super+z para aplicar la barra y la configuración."
