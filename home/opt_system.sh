#!/usr/bin/env bash
# scx-autogame.sh — Auto-switch SCX sched-ext between NORMAL and GAMING
# Arch/Zen + scxctl
set -euo pipefail

# ---------------------------
# Defaults (customizable via env)
# ---------------------------
NORMAL_SCHED="${NORMAL_SCHED:-bpfland}"
NORMAL_MODE="${NORMAL_MODE:-auto}"

GAMING_SCHED="${GAMING_SCHED:-bpfland}"
GAMING_MODE="${GAMING_MODE:-gaming}"

# If ATS is detected, you can choose a different sched/mode (optional)
ATS_SCHED="${ATS_SCHED:-$GAMING_SCHED}"
ATS_MODE="${ATS_MODE:-$GAMING_MODE}"

INTERVAL="${INTERVAL:-2}"          # seconds between checks
COOLDOWN="${COOLDOWN:-10}"         # keep GAMING this many seconds after game disappears (avoid flapping)
VERBOSE="${VERBOSE:-1}"            # 0 silent, 1 info

ATS_APPID="270880"

# RetroArch + emulator processes (feel free to add/remove)
EMULATOR_REGEX="${EMULATOR_REGEX:-(^|/)(retroarch|rpcs3|pcsx2|dolphin-emu|cemu|yuzu|ryujinx|duckstation|ppsspp|mame|mupen64plus|mgba|citra|desmume|vita3k)(\s|$)}"

# ---------------------------
# Helpers
# ---------------------------
log() { [[ "$VERBOSE" -eq 1 ]] && echo "[scx-autogame] $*"; }
die() { echo "[scx-autogame] ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "No encuentro '$1' en PATH."; }

run_scxctl() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    scxctl "$@"
  else
    sudo scxctl "$@"
  fi
}

scx_supported() {
  scxctl list >/dev/null 2>&1
}

ensure_sched_exists() {
  local s="$1"
  scxctl list 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q "\"$(echo "$s" | tr '[:upper:]' '[:lower:]')\"" \
    || die "Scheduler '$s' no aparece en 'scxctl list'."
}

current_scx_line() {
  scxctl get 2>/dev/null || true
}

is_in_mode() {
  # args: sched mode
  local want_sched="$1" want_mode="$2" out
  out="$(current_scx_line)"
  # Example: "running Bpfland in Auto mode"
  echo "$out" | awk -v s="$want_sched" -v m="$want_mode" '
    BEGIN{IGNORECASE=1}
    {line=tolower($0)}
    END{
      if (index(line, "running " tolower(s)) && index(line, " in " tolower(m) " mode")) exit 0;
      exit 1
    }'
}

switch_to() {
  local sched="$1" mode="$2" reason="$3"
  ensure_sched_exists "$sched"
  if is_in_mode "$sched" "$mode"; then
    [[ -n "${reason:-}" ]] && log "Ya estoy en $sched/$mode (reason: $reason)"
    return 0
  fi
  run_scxctl switch -s "$sched" -m "$mode"
  log "Cambio -> $sched / $mode  (${reason:-})"
}

stop_scx() {
  run_scxctl stop
  log "SCX stop -> volviendo al scheduler normal del kernel"
}

# ---------------------------
# Detection
# ---------------------------

# Fast ATS detection (native/proton exe name) + SteamAppId env match
ats_running() {
  # common exe names / process cmdlines (Proton and native)
  if pgrep -u "$UID" -f '(AmericanTruckSimulator\.exe|amtrucks)' >/dev/null 2>&1; then
    return 0
  fi

  # fallback: check SteamAppId=270880 in environ of likely Steam game processes
  local p
  while read -r p; do
    [[ -r "/proc/$p/environ" ]] || continue
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "SteamAppId=$ATS_APPID"; then
      return 0
    fi
  done < <(pgrep -u "$UID" -f 'steamapps/common|compatdata|pressure-vessel|wine|wineserver|proton|wine64-preloader|wine-preloader|reaper' 2>/dev/null || true)

  return 1
}

# Detect any Steam game by checking SteamAppId in /proc/<pid>/environ
# Excludes Steam client id 769 (common) to avoid false positive.
steam_game_running() {
  local p appid
  while read -r p; do
    [[ -r "/proc/$p/environ" ]] || continue
    appid="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | awk -F= '$1=="SteamAppId"{print $2; exit}')"
    [[ -z "${appid:-}" ]] && continue
    [[ "$appid" == "0" || "$appid" == "769" ]] && continue
    # found a real Steam app/game process
    echo "$appid"
    return 0
  done < <(pgrep -u "$UID" -f 'steamapps/common|compatdata|pressure-vessel|wine|wineserver|proton|wine64-preloader|wine-preloader|reaper|gamescope' 2>/dev/null || true)

  return 1
}

# Detect emulators (including RetroArch)
emulator_running() {
  local p cmd
  while read -r p; do
    [[ -r "/proc/$p/cmdline" ]] || continue
    cmd="$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null || true)"
    [[ -z "$cmd" ]] && continue
    if echo "$cmd" | grep -Eqi "$EMULATOR_REGEX"; then
      echo "$cmd" | awk '{print $1}'
      return 0
    fi
  done < <(pgrep -u "$UID" -f 'retroarch|rpcs3|pcsx2|dolphin-emu|cemu|yuzu|ryujinx|duckstation|ppsspp|mame|mupen64plus|mgba|citra|desmume|vita3k' 2>/dev/null || true)

  return 1
}

# Decide: normal vs gaming (and which profile)
decide_profile() {
  # ATS has priority
  if ats_running; then
    echo "ATS"
    return 0
  fi

  # any Steam game?
  local appid
  if appid="$(steam_game_running)"; then
    echo "STEAM:$appid"
    return 0
  fi

  # emulators?
  local emu
  if emu="$(emulator_running)"; then
    echo "EMU:$emu"
    return 0
  fi

  echo "NONE"
}

# ---------------------------
# Main
# ---------------------------
usage() {
  cat <<EOF
Uso:
  $(basename "$0") daemon   # (default) loop detectando juegos y cambiando SCX
  $(basename "$0") once     # una sola detección y cambio
  $(basename "$0") status   # muestra estado actual (scxctl get)
  $(basename "$0") normal   # fuerza modo normal
  $(basename "$0") gaming   # fuerza modo gaming (general)
  $(basename "$0") off      # scxctl stop (scheduler normal del kernel)

Variables útiles:
  NORMAL_SCHED=bpfland  NORMAL_MODE=auto
  GAMING_SCHED=bpfland  GAMING_MODE=gaming
  ATS_SCHED=lavd        ATS_MODE=gaming
  INTERVAL=2 COOLDOWN=10 VERBOSE=1

Ejemplos:
  ATS con LAVD:
    ATS_SCHED=lavd $(basename "$0") daemon

  Más agresivo:
    GAMING_SCHED=flash $(basename "$0") daemon
EOF
}

main() {
  need scxctl
  scx_supported || die "scxctl no responde. ¿Tienes scx-tools/scx-scheds instalados y sched-ext activo?"

  local cmd="${1:-daemon}"
  case "$cmd" in
    status)
      current_scx_line
      exit 0
      ;;
    normal)
      switch_to "$NORMAL_SCHED" "$NORMAL_MODE" "forced normal"
      exit 0
      ;;
    gaming)
      switch_to "$GAMING_SCHED" "$GAMING_MODE" "forced gaming"
      exit 0
      ;;
    off)
      stop_scx
      exit 0
      ;;
    once|daemon)
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "Comando inválido: $cmd (usa --help)"
      ;;
  esac

  ensure_sched_exists "$NORMAL_SCHED"
  ensure_sched_exists "$GAMING_SCHED"
  ensure_sched_exists "$ATS_SCHED"

  local last_state="NONE"
  local last_gaming_ts=0
  local now state

  if [[ "$cmd" == "once" ]]; then
    state="$(decide_profile)"
    log "Detectado: $state"
    if [[ "$state" == "ATS" ]]; then
      switch_to "$ATS_SCHED" "$ATS_MODE" "ATS"
    elif [[ "$state" == STEAM:* ]]; then
      switch_to "$GAMING_SCHED" "$GAMING_MODE" "$state"
    elif [[ "$state" == EMU:* ]]; then
      switch_to "$GAMING_SCHED" "$GAMING_MODE" "$state"
    else
      switch_to "$NORMAL_SCHED" "$NORMAL_MODE" "no games"
    fi
    exit 0
  fi

  log "Daemon iniciado. NORMAL=$NORMAL_SCHED/$NORMAL_MODE  GAMING=$GAMING_SCHED/$GAMING_MODE  ATS=$ATS_SCHED/$ATS_MODE"
  while true; do
    now="$(date +%s)"
    state="$(decide_profile)"

    if [[ "$state" != "NONE" ]]; then
      last_gaming_ts="$now"
      if [[ "$state" == "ATS" ]]; then
        switch_to "$ATS_SCHED" "$ATS_MODE" "ATS detected"
      else
        switch_to "$GAMING_SCHED" "$GAMING_MODE" "$state detected"
      fi
    else
      # cooldown to avoid flapping when Proton/Steam is tearing down processes
      if (( now - last_gaming_ts >= COOLDOWN )); then
        switch_to "$NORMAL_SCHED" "$NORMAL_MODE" "cooldown passed"
      fi
    fi

    if [[ "$state" != "$last_state" ]]; then
      log "Estado: $state"
      last_state="$state"
    fi

    sleep "$INTERVAL"
  done
}

main "$@"
