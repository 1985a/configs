#!/bin/bash
# Panel que muestra la carátula de la canción actual con kitty (funciona dentro de tmux,
# necesita "set -g allow-passthrough on" en ~/.tmux.conf). Se actualiza al cambiar de
# canción y al cambiar el tamaño del panel. Lo abre ~/.local/bin/ncmpcpp-cover.

COVER="$HOME/.ncmpcpp/cover.sh"
SCALED=$(mktemp --suffix=.png)
last=""

draw() {
    printf '\e[?25l\e[2J\e[H'    # oculta cursor y limpia
    kitty +kitten icat --clear --silent 2>/dev/null

    local img cols rows cw ch
    if img=$("$COVER"); then
        # la escalo yo al tamaño del panel en píxeles: con --scale-up icat calcula mal
        # el tamaño de celda dentro de tmux y la imagen sale rayada
        # una columna y una línea libres: si la imagen llena la línea, el terminal salta
        # de línea solo y icat añade otro salto, dejando franjas vacías
        cols=$(( $(tput cols) - 1 )); rows=$(( $(tput lines) - 1 ))
        read -r cw ch < <(tmux display -p -t "$TMUX_PANE" '#{client_cell_width} #{client_cell_height}' 2>/dev/null)
        [[ $cw =~ ^[0-9]+$ && $cw -gt 0 ]] || cw=10
        [[ $ch =~ ^[0-9]+$ && $ch -gt 0 ]] || ch=22
        ffmpeg -v error -y -i "$img" -vf \
            "scale=$((cols * cw)):$((rows * ch)):force_original_aspect_ratio=decrease" \
            "$SCALED" </dev/null && img="$SCALED"
        # --unicode-placeholder: la imagen va en caracteres especiales que tmux guarda
        # como texto, así no desaparece cuando tmux repinta el panel
        kitty +kitten icat --silent --stdin=no --unicode-placeholder \
            --passthrough=tmux --place "${cols}x${rows}@0x0" "$img" 2>/dev/null
    else
        printf '\n  sin carátula'
    fi
}

redraw_if_changed() {
    local now
    now=$(mpc -f %file% current 2>/dev/null)
    [[ "$now" == "$last" ]] && return
    last="$now"
    draw
}

resized=0
trap 'resized=1' WINCH
trap 'kitty +kitten icat --clear --silent 2>/dev/null; rm -f "$SCALED"; exit' INT TERM HUP

redraw_if_changed
while :; do
    # mpc idleloop en un descriptor aparte: así "read" se interrumpe con WINCH y el
    # panel se redibuja al redimensionar, sin esperar al siguiente cambio de canción
    exec 3< <(mpc idleloop player 2>/dev/null)
    while :; do
        read -r -u 3 -t 0.3 _
        rc=$?
        if (( rc > 128 )); then       # timeout o WINCH: redibuja si cambió el tamaño
            (( resized )) && { resized=0; draw; }
            continue
        fi
        (( rc != 0 )) && break        # mpd se cayó o se reinició
        redraw_if_changed
    done
    exec 3<&-
    sleep 3                           # reintenta conectar con mpd
    last=""
    redraw_if_changed
done
