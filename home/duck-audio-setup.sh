#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# duck-audio-setup.sh
# Setup rápido para:
#   MPD   -> MPD_Music_Duck -> Carla/LSP Sidechain Compressor -> EasyEffects
#   Brave -> Brave_Voice_Duck -> EasyEffects + sidechain de Carla
#
# Uso:
#   ./duck-audio-setup.sh
#   ./duck-audio-setup.sh /ruta/al/perfil.carxp
# ============================================================

CARLA_PROJECT_DEFAULT="$HOME/.config/carla/audio-jevi-easy-effect-mas-carla-jack_VIRTUAL_SINKS.carxp"
CARLA_PROJECT="${1:-$CARLA_PROJECT_DEFAULT}"

BRAVE_SINK_NAME="brave_voice_duck"
BRAVE_SINK_DESC="Brave_Voice_Duck"

MPD_SINK_NAME="mpd_music_duck"
MPD_SINK_DESC="MPD_Music_Duck"

# Cambia a 96000 si tus sinks virtuales deben trabajar a 96 kHz.
SINK_RATE="48000"

log()  { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "No encuentro el comando: $1"
        return 1
    fi
}

wait_pactl() {
    info "Esperando PipeWire/PulseAudio API..."
    for _ in {1..30}; do
        if pactl info >/dev/null 2>&1; then
            log "pactl responde correctamente."
            return 0
        fi
        sleep 1
    done
    err "pactl no responde. Revisa pipewire, pipewire-pulse y wireplumber."
    return 1
}

sink_exists() {
    pactl list short sinks | awk '{print $2}' | grep -qx "$1"
}

create_sink_if_missing() {
    local name="$1"
    local desc="$2"

    if sink_exists "$name"; then
        log "Sink existente: $name ($desc)"
        return 0
    fi

    info "Creando sink virtual: $name ($desc)"
    pactl load-module module-null-sink \
        sink_name="$name" \
        sink_properties=device.description="$desc" \
        channels=2 \
        channel_map=front-left,front-right \
        rate="$SINK_RATE" >/dev/null

    sleep 0.5

    if sink_exists "$name"; then
        log "Sink creado: $name"
    else
        err "No se pudo crear el sink: $name"
        return 1
    fi
}

start_easyeffects() {
    if pgrep -x easyeffects >/dev/null 2>&1; then
        log "EasyEffects ya está ejecutándose."
        return 0
    fi

    if command -v easyeffects >/dev/null 2>&1; then
        info "Iniciando EasyEffects..."
        nohup easyeffects >/tmp/duck-easyeffects.log 2>&1 &
        sleep 2
    elif command -v flatpak >/dev/null 2>&1 && flatpak info com.github.wwmm.easyeffects >/dev/null 2>&1; then
        info "Iniciando EasyEffects Flatpak..."
        nohup flatpak run com.github.wwmm.easyeffects >/tmp/duck-easyeffects.log 2>&1 &
        sleep 3
    else
        err "EasyEffects no parece estar instalado como binario nativo ni Flatpak."
        return 1
    fi

    if pgrep -x easyeffects >/dev/null 2>&1 || pgrep -f "com.github.wwmm.easyeffects" >/dev/null 2>&1; then
        log "EasyEffects iniciado."
    else
        warn "No pude confirmar EasyEffects con pgrep. Revisa /tmp/duck-easyeffects.log."
    fi
}

find_easyeffects_sink() {
    pactl list short sinks | awk '{print $2}' | grep -Ei 'easyeffects|easy_effects|ee_' | head -n1 || true
}

check_easyeffects_sink() {
    local ee_sink
    ee_sink="$(find_easyeffects_sink)"

    if [[ -n "$ee_sink" ]]; then
        log "Sink de EasyEffects detectado: $ee_sink"
    else
        warn "No veo el sink de EasyEffects todavía. Abre EasyEffects y verifica que Effects esté activado para salida."
    fi
}

start_carla_project() {
    if [[ ! -f "$CARLA_PROJECT" ]]; then
        err "No encuentro el proyecto de Carla:"
        err "  $CARLA_PROJECT"
        err "Copia el archivo .carxp ahí o ejecuta:"
        err "  $0 /ruta/al/archivo.carxp"
        return 1
    fi

    if ! command -v pw-jack >/dev/null 2>&1; then
        err "No encuentro pw-jack. Instala pipewire-jack."
        return 1
    fi

    if ! command -v carla >/dev/null 2>&1; then
        err "No encuentro carla. Instala carla."
        return 1
    fi

    if pgrep -x carla >/dev/null 2>&1; then
        warn "Carla ya está ejecutándose. No abriré otra instancia."
        warn "Si quieres recargar el proyecto, cierra Carla y ejecuta este script otra vez."
        return 0
    fi

    info "Abriendo Carla con el proyecto:"
    info "  $CARLA_PROJECT"
    nohup pw-jack carla "$CARLA_PROJECT" >/tmp/duck-carla.log 2>&1 &
    sleep 3

    if pgrep -x carla >/dev/null 2>&1; then
        log "Carla iniciado con pw-jack."
    else
        warn "No pude confirmar Carla con pgrep. Revisa /tmp/duck-carla.log."
    fi
}

sink_id_to_name() {
    local id="$1"
    pactl list short sinks | awk -v sid="$id" '$1 == sid {print $2}'
}

check_stream_routes() {
    info "Revisando rutas actuales de Brave y MPD..."

    local inputs
    inputs="$(pactl list sink-inputs 2>/dev/null || true)"

    if [[ -z "$inputs" ]]; then
        warn "No hay streams de audio activos ahora mismo."
        warn "Pon a sonar MPD y Brave/YouTube para verificar las rutas."
        return 0
    fi

    local current_id=""
    local current_sink=""
    local current_app=""
    local found_any=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^Sink\ Input\ \#([0-9]+) ]]; then
            current_id="${BASH_REMATCH[1]}"
            current_sink=""
            current_app=""
        elif [[ "$line" =~ ^[[:space:]]*Sink:\ ([0-9]+) ]]; then
            current_sink="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ application\.name\ =\ \"(.*)\" ]]; then
            current_app="${BASH_REMATCH[1]}"
            local app_lc="${current_app,,}"

            if [[ "$app_lc" == *brave* || "$app_lc" == *"music player daemon"* || "$app_lc" == *mpd* ]]; then
                found_any=1
                local sname
                sname="$(sink_id_to_name "$current_sink")"

                if [[ "$app_lc" == *brave* ]]; then
                    if [[ "$sname" == "$BRAVE_SINK_NAME" ]]; then
                        log "Brave stream #$current_id está en $sname"
                    else
                        warn "Brave stream #$current_id está en $sname, debería estar en $BRAVE_SINK_NAME"
                        warn "Lanza Brave con: PULSE_SINK=$BRAVE_SINK_NAME brave"
                    fi
                else
                    if [[ "$sname" == "$MPD_SINK_NAME" ]]; then
                        log "MPD stream #$current_id está en $sname"
                    else
                        warn "MPD stream #$current_id está en $sname, debería estar en $MPD_SINK_NAME"
                        warn "Configura en mpd.conf: sink \"$MPD_SINK_NAME\""
                    fi
                fi
            fi
        fi
    done <<< "$inputs"

    if [[ "$found_any" -eq 0 ]]; then
        warn "No vi streams activos de Brave o MPD en este momento."
    fi
}

print_final_notes() {
    cat <<EOF

============================================================
RUTEO ESPERADO
============================================================

En pavucontrol debe quedar así:

  Brave            -> $BRAVE_SINK_DESC
  mpd.MPD-pipe     -> $MPD_SINK_DESC

En Carla / qpwgraph:

  $MPD_SINK_DESC monitor_FL/FR   -> LSP Input L/R
  $BRAVE_SINK_DESC monitor_FL/FR -> LSP Sidechain input L/R
  $BRAVE_SINK_DESC monitor_FL/FR -> EasyEffects Sink playback_FL/FR
  LSP Output L/R                 -> EasyEffects Sink playback_FL/FR

Para lanzar Brave siempre por el sink correcto:

  PULSE_SINK=$BRAVE_SINK_NAME brave

Para MPD, en mpd.conf debe existir algo como:

  audio_output {
      type "pulse"
      name "MPD-pipe"
      sink "$MPD_SINK_NAME"
  }

Logs útiles:

  /tmp/duck-carla.log
  /tmp/duck-easyeffects.log

============================================================
EOF
}

main() {
    need_cmd pactl || exit 1
    wait_pactl

    create_sink_if_missing "$BRAVE_SINK_NAME" "$BRAVE_SINK_DESC"
    create_sink_if_missing "$MPD_SINK_NAME" "$MPD_SINK_DESC"

    start_easyeffects
    sleep 1
    check_easyeffects_sink

    start_carla_project

    check_stream_routes
    print_final_notes
}

main "$@"
