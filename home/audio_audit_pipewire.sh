#!/usr/bin/env bash
# Recoge en un .tar.gz todo lo útil para diagnosticar el audio (PipeWire, WirePlumber,
# ALSA, IRQs, EasyEffects, Carla, MPD). Solo lee; no cambia nada.
# Uso: audio_audit_pipewire.sh      -> ~/audio-audit-FECHA.tar.gz
set -u

TS="$(date +%Y%m%d_%H%M%S)"
OUT="$HOME/audio-audit-$TS"
mkdir -p "$OUT"

run() {
  local name="$1"; shift
  {
    echo "### COMMAND: $*"
    echo "### DATE: $(date)"
    echo
    "$@"
  } > "$OUT/$name.txt" 2>&1
}

run_sh() {
  local name="$1"; shift
  {
    echo "### COMMAND: $*"
    echo "### DATE: $(date)"
    echo
    # "bash -c" y no "bash -lc": un shell de login carga ~/.bash_profile, que puede
    # arrancar sway o startx
    bash -c "$*"
  } > "$OUT/$name.txt" 2>&1
}

# Sistema base
run 00-system uname -a
run 01-os-release cat /etc/os-release
run_sh 02-packages "pacman -Q pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack alsa-utils alsa-ucm-conf alsa-card-profiles easyeffects carla lsp-plugins calf zam-plugins 2>/dev/null || true"
run_sh 03-audio-processes "ps -ef | grep -Ei 'pipewire|wireplumber|pulse|jack|carla|easyeffects|mpd|brave|obs' | grep -v grep || true"

# Servicios
run_sh 10-systemd-user-audio "systemctl --user status pipewire pipewire-pulse wireplumber easyeffects mpd --no-pager -l || true"
run_sh 11-systemd-user-failed "systemctl --user --failed --no-pager || true"
run_sh 12-journal-audio "journalctl --user -b -u pipewire -u pipewire-pulse -u wireplumber -u easyeffects -u mpd --no-pager || true"

# PipeWire
run_sh 20-pw-dump "pw-dump || true"
run_sh 21-pw-cli-info "pw-cli info all || true"
run_sh 22-pw-top-once "timeout 5s pw-top -b || true"
run_sh 23-pw-link "pw-link -l || true"
run_sh 24-pw-metadata "pw-metadata -n settings 0 || true"
run_sh 25-wpctl-status "wpctl status || true"
run_sh 26-wpctl-inspect-all "wpctl status | sed -n '/Sinks:/,/Sources:/p' || true"

# ALSA / tarjeta
run_sh 30-lspci-audio "lspci -nnk | grep -A6 -Ei 'audio|multimedia|creative|ca0132|sound' || true"
run_sh 31-lsusb-audio "lsusb || true"
run_sh 32-aplay-devices "aplay -lL || true"
run_sh 33-arecord-devices "arecord -lL || true"
run_sh 34-proc-asound "find /proc/asound -maxdepth 3 -type f -print -exec sh -c 'echo === {}; cat {} 2>/dev/null | head -200' \\; || true"
run_sh 35-alsa-cards "cat /proc/asound/cards /proc/asound/modules /proc/asound/version 2>/dev/null || true"
run_sh 36-alsactl-dump "alsactl info 2>/dev/null || true; alsactl dump-state 2>/dev/null || true"
run_sh 37-amixer-all "for c in \$(awk '{print \$1}' /proc/asound/cards 2>/dev/null | grep -E '^[0-9]+$'); do echo ===== CARD \$c =====; amixer -c \$c contents; amixer -c \$c scontents; done"

# Configuración PipeWire / WirePlumber / ALSA
run_sh 40-pipewire-configs "find /etc/pipewire /usr/share/pipewire ~/.config/pipewire -maxdepth 4 -type f 2>/dev/null | sort"
run_sh 41-wireplumber-configs "find /etc/wireplumber /usr/share/wireplumber ~/.config/wireplumber -maxdepth 5 -type f 2>/dev/null | sort"
run_sh 42-alsa-configs "find /etc/alsa /usr/share/alsa ~/.config/alsa -maxdepth 5 -type f 2>/dev/null | sort"
run_sh 43-selected-audio-config-content "for f in ~/.config/pipewire/* ~/.config/pipewire/pipewire.conf.d/* ~/.config/wireplumber/* ~/.config/wireplumber/wireplumber.conf.d/* ~/.asoundrc /etc/asound.conf; do [ -f \"\$f\" ] && echo ===== \$f ===== && sed -n '1,220p' \"\$f\"; done"

# Kernel / realtime / IRQ
run_sh 50-kernel-modules "lsmod | grep -Ei 'snd|ca0132|hda|pipewire|v4l2loopback' || true"
run_sh 51-rt-priority "ulimit -a; echo; groups; echo; chrt -m || true"
run_sh 52-rtkit "systemctl status rtkit-daemon --no-pager -l || true"
run_sh 53-interrupts "grep -Ei 'snd|hda|audio|creative|nvidia|xhci|usb|nvme' /proc/interrupts || true"
run_sh 54-cpu-governor "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo \$f: \$(cat \$f 2>/dev/null); done | head -80"

# EasyEffects / Carla / MPD
run_sh 60-easyeffects "easyeffects --version 2>/dev/null || true; find ~/.config/easyeffects -maxdepth 4 -type f -print 2>/dev/null | sort"
run_sh 61-carla "carla --version 2>/dev/null || true; find ~/.config/falkTX ~/.config/Carla -maxdepth 4 -type f -print 2>/dev/null | sort"
run_sh 62-mpd "mpd --version 2>/dev/null | head -80 || true; systemctl --user status mpd --no-pager -l || true; cat ~/.config/mpd/mpd.conf ~/.mpd/mpd.conf /etc/mpd.conf 2>/dev/null || true"

# Latencia / formatos disponibles
run_sh 70-audio-latency-props "pw-metadata -n settings 0 clock.rate clock.allowed-rates clock.quantum clock.min-quantum clock.max-quantum clock.force-quantum clock.force-rate 2>/dev/null || true"
run_sh 71-device-props "pw-dump | grep -Ei 'alsa.card_name|alsa.driver_name|audio.rate|audio.channels|api.alsa.period|api.alsa.headroom|node.latency|clock.quantum|session.suspend-timeout-seconds|device.profile|card.profile' || true"

# Resumen rápido
{
  echo "Audio audit generado: $OUT"
  echo
  echo "Servicios fallidos:"
  systemctl --user --failed --no-pager || true
  echo
  echo "wpctl status:"
  wpctl status || true
  echo
  echo "Tarjetas ALSA:"
  cat /proc/asound/cards 2>/dev/null || true
} > "$OUT/99-summary.txt" 2>&1

tar -czf "$HOME/audio-audit-$TS.tar.gz" -C "$HOME" "$(basename "$OUT")"

echo
echo "LISTO:"
echo "$HOME/audio-audit-$TS.tar.gz"
