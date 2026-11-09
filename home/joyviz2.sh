#!/usr/bin/env bash
# joyviz.sh - visor de joystick en consola (auto-detect + hotplug + mapeo + colores)
# Requisitos: paquete "joystick" (jstest/jscal). En Arch: sudo pacman -S joystick

[[ -n "${BASH_VERSION:-}" ]] || { echo "Este script requiere bash. Usa: bash $0"; exit 1; }

set -u
set -o pipefail
shopt -s nullglob

# -------------------------
# Utilidades
# -------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1'. En Arch: sudo pacman -S joystick"; exit 1; }; }
is_tty() { [[ -t 0 && -t 1 ]]; }
resolve_real() { readlink -f "$1" 2>/dev/null || true; }
abs_i() { local x="$1"; (( x<0 )) && echo $(( -x )) || echo "$x"; }

cleanup() {
  # Restaurar pantalla/cursor
  if [[ "${ALT_SCREEN:-0}" == "1" ]]; then
    printf "[?1049l" 2>/dev/null || true
  fi
  tput cnorm 2>/dev/null || true
  tput sgr0  2>/dev/null || true
  printf "
"
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

# -------------------------
# Colores (TrueColor si hay TTY)
# -------------------------
NO_COLOR="${NO_COLOR:-0}"
COLOR_ENABLED=1
if ! [[ -t 1 ]]; then COLOR_ENABLED=0; fi
if [[ "$NO_COLOR" == "1" ]]; then COLOR_ENABLED=0; fi

# UI: usar pantalla alternativa para evitar scroll/flicker
ALT_SCREEN=0
if [[ -t 1 ]]; then
  ALT_SCREEN=1
fi

ansi_rgb()   { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
ansi_bold()  { printf '\033[1m'; }
ansi_reset() { printf '\033[0m'; }

label_rgb_for_profile() {
  local p="$1" lbl="$2"
  case "$p" in
    xbox)
      case "$lbl" in
        A) echo "0 200 0" ;; B) echo "220 0 0" ;; X) echo "0 120 255" ;; Y) echo "255 215 0" ;;
      esac
      ;;
    sony|ps3)
      case "$lbl" in
        "△") echo "0 200 0" ;; "○") echo "220 0 0" ;; "✕") echo "0 120 255" ;; "□") echo "255 0 180" ;;
      esac
      ;;
    nintendo)
      case "$lbl" in
        A) echo "220 0 0" ;; B) echo "255 215 0" ;; X) echo "0 120 255" ;; Y) echo "0 200 0" ;;
      esac
      ;;
  esac
}

colorize_label_padded() {
  local p="$1" raw="$2" pressed="$3" label_w="$4"
  local padded rgb r g b
  padded="$(printf "%-${label_w}s" "$raw")"

  if [[ "$COLOR_ENABLED" == "0" ]]; then
    printf "%s" "$padded"
    return 0
  fi

  rgb="$(label_rgb_for_profile "$p" "$raw" || true)"
  if [[ -z "$rgb" ]]; then
    [[ "$pressed" == "X" ]] && printf "%s%s%s" "$(ansi_bold)" "$padded" "$(ansi_reset)" || printf "%s" "$padded"
    return 0
  fi
  read -r r g b <<<"$rgb"
  if [[ "$pressed" == "X" ]]; then
    printf "%s%s%s%s" "$(ansi_bold)" "$(ansi_rgb "$r" "$g" "$b")" "$padded" "$(ansi_reset)"
  else
    printf "%s%s%s" "$(ansi_rgb "$r" "$g" "$b")" "$padded" "$(ansi_reset)"
  fi
}

# -------------------------
# Ayuda
# -------------------------
usage() {
  cat <<'EOF'
joyviz.sh - visor de joystick en consola (AUTO).

Uso:
  joyviz.sh [opciones]            # auto: detecta el primer mando disponible
  joyviz.sh [opciones] /dev/input/jsX

Opciones:
  --profile auto|xbox|sony|ps3|nintendo|fightstick
  --follow auto|direct|by-path|by-id     (default: auto; recomendado Mayflash: by-path)
  --raw                                (solo Bxx/Axx, sin labels)
  --no-auto-calibrate                  (no preguntar calibración)
  --auto-calibrate                     (si no hay mapa, calibrar sin preguntar)
  -h, --help

Salida:
  Ctrl+C para salir.
  Combo (mantener ~0.7s):
    Xbox: Menu + View
    Nintendo: +  +  -
    Sony/PS3: Start + Select
EOF
}

# -------------------------
# Dependencias
# -------------------------
need_cmd jstest
need_cmd stdbuf
need_cmd tput
need_cmd readlink
need_cmd sed
need_cmd wc
need_cmd date

# Entrar a pantalla alternativa (evita scroll) y ocultar cursor
if [[ "${ALT_SCREEN:-0}" == "1" ]]; then
  printf "\033[?1049h\033[H" 2>/dev/null || true
  tput civis 2>/dev/null || true
fi

# -------------------------
# Args
# -------------------------
profile="auto"
follow="auto"
raw_mode="0"
no_auto_cal="0"
force_auto_cal="0"
pick_dev=""

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --profile) shift; profile="${1:-auto}" ;;
    --follow)  shift; follow="${1:-auto}" ;;
    --raw) raw_mode="1" ;;
    --no-auto-calibrate) no_auto_cal="1" ;;
    --auto-calibrate) force_auto_cal="1" ;;
    /dev/input/js*) pick_dev="$1" ;;
    *) echo "Argumento desconocido: $1"; usage; exit 1 ;;
  esac
  shift || true
done

# -------------------------
# Detect/anchor helpers
# -------------------------
find_anchor_link() {
  local js="$1"
  local want; want="$(resolve_real "$js")"
  [[ -z "$want" ]] && return 1

  if [[ -d /dev/input/by-path ]]; then
    for l in /dev/input/by-path/*-joystick; do
      [[ -e "$l" ]] || continue
      [[ "$(resolve_real "$l")" == "$want" ]] && { echo "$l"; return 0; }
    done
  fi
  if [[ -d /dev/input/by-id ]]; then
    for l in /dev/input/by-id/*-joystick; do
      [[ -e "$l" ]] || continue
      [[ "$(resolve_real "$l")" == "$want" ]] && { echo "$l"; return 0; }
    done
  fi
  return 1
}

auto_pick_js() {
  # AUTO: elige el primer joystick disponible.
  # Importante: si usamos /dev/input/by-path o by-id, validamos que el destino exista.
  local c d
  for c in /dev/input/by-path/*-joystick; do
    [[ -e "$c" ]] || continue
    d="$(resolve_real "$c")"
    [[ -n "$d" && -e "$d" ]] && { echo "$d"; return 0; }
  done
  for c in /dev/input/by-id/*-joystick; do
    [[ -e "$c" ]] || continue
    d="$(resolve_real "$c")"
    [[ -n "$d" && -e "$d" ]] && { echo "$d"; return 0; }
  done
  local js=(/dev/input/js*)
  (( ${#js[@]} > 0 )) || return 1
  echo "${js[0]}"
}

brand_from_vid() {
  case "${1,,}" in
    045e) echo "Microsoft (Xbox)" ;;
    054c) echo "Sony (PlayStation)" ;;
    057e) echo "Nintendo" ;;
    0079) echo "Mayflash/Venom/Longshengwei" ;;
    *)    echo "Desconocido" ;;
  esac
}

guess_profile() {
  local vid="$1" pid="$2" name_lc="$3"
  [[ "${vid,,}:${pid,,}" == "054c:0268" ]] && { echo "ps3"; return; }
  case "${vid,,}" in
    045e) echo "xbox"; return ;;
    054c) echo "sony"; return ;;
    057e) echo "nintendo"; return ;;
    0079) echo "fightstick"; return ;;
  esac
  [[ "$name_lc" == *"playstation(r)3"* || "$name_lc" == *"sixaxis"* || "$name_lc" == *"ps3"* ]] && { echo "ps3"; return; }
  [[ "$name_lc" == *"xbox"* || "$name_lc" == *"xinput"* ]] && { echo "xbox"; return; }
  [[ "$name_lc" == *"dualsense"* || "$name_lc" == *"dualshock"* ]] && { echo "sony"; return; }
  [[ "$name_lc" == *"switch"* || "$name_lc" == *"joy-con"* || "$name_lc" == *"pro controller"* ]] && { echo "nintendo"; return; }
  [[ "$name_lc" == *"mayflash"* || "$name_lc" == *"venom"* || "$name_lc" == *"dragonrise"* || "$name_lc" == *"fightstick"* || "$name_lc" == *"arcade"* ]] && { echo "fightstick"; return; }
  echo "auto"
}

mode_guess() {
  local vid="$1" pid="$2" name_lc="$3"
  [[ "${vid,,}:${pid,,}" == "054c:0268" ]] && { echo "PlayStation 3 HID-like"; return; }
  [[ "${vid,,}" == "045e" || "$name_lc" == *"xbox"* || "$name_lc" == *"xinput"* ]] && { echo "XInput-like"; return; }
  [[ "${vid,,}" == "057e" || "$name_lc" == *"switch"* || "$name_lc" == *"joy-con"* || "$name_lc" == *"pro controller"* ]] && { echo "Nintendo HID-like"; return; }
  [[ "${vid,,}" == "054c" || "$name_lc" == *"dualshock"* || "$name_lc" == *"dualsense"* ]] && { echo "PlayStation HID-like"; return; }
  [[ "${vid,,}" == "0079" || "$name_lc" == *"mayflash"* || "$name_lc" == *"venom"* || "$name_lc" == *"dragonrise"* ]] && { echo "DirectInput-like"; return; }
  echo "Genérico"
}

# -------------------------
# Mapas persistentes
# -------------------------
map_dir="${HOME}/.config/joyviz/maps"
mkdir -p "$map_dir"
map_file_for() { local vidpid="$1" p="$2"; echo "${map_dir}/${vidpid}.${p}.map"; }

declare -A BTN_LABELS
declare -a DISPLAY_BUTTONS

DPAD_MODE="none"    # axes|buttons|none
DPAD_X_AXIS=-1
DPAD_Y_AXIS=-1
DPAD_BTN_UP=-1
DPAD_BTN_DOWN=-1
DPAD_BTN_LEFT=-1
DPAD_BTN_RIGHT=-1

load_map_if_exists() {
  local f="$1"
  [[ -r "$f" ]] || return 1
  # shellcheck disable=SC1090
  source "$f" 2>/dev/null || return 1
  return 0
}

set_profile_defaults() {
  local p="$1"
  BTN_LABELS=()
  DISPLAY_BUTTONS=()

  DPAD_MODE="none"
  DPAD_X_AXIS=-1
  DPAD_Y_AXIS=-1
  DPAD_BTN_UP=-1
  DPAD_BTN_DOWN=-1
  DPAD_BTN_LEFT=-1
  DPAD_BTN_RIGHT=-1

  case "$p" in
    xbox)
      BTN_LABELS[0]="A"; BTN_LABELS[1]="B"; BTN_LABELS[2]="X"; BTN_LABELS[3]="Y"
      BTN_LABELS[4]="LB"; BTN_LABELS[5]="RB"
      BTN_LABELS[6]="View"; BTN_LABELS[7]="Menu"
      BTN_LABELS[8]="L3"; BTN_LABELS[9]="R3"
      BTN_LABELS[10]="Guide"
      BTN_LABELS[11]="Share"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 11 8 9 10)
      DPAD_MODE="axes"; DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    sony)
      BTN_LABELS[0]="✕"; BTN_LABELS[1]="○"; BTN_LABELS[2]="□"; BTN_LABELS[3]="△"
      BTN_LABELS[4]="L1"; BTN_LABELS[5]="R1"
      BTN_LABELS[6]="Share"; BTN_LABELS[7]="Options"
      BTN_LABELS[8]="L3"; BTN_LABELS[9]="R3"
      BTN_LABELS[10]="PS"; BTN_LABELS[11]="Touchpad"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 8 9 10 11)
      DPAD_MODE="axes"; DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    ps3)
      BTN_LABELS[0]="✕"; BTN_LABELS[1]="○"; BTN_LABELS[2]="□"; BTN_LABELS[3]="△"
      BTN_LABELS[4]="L1"; BTN_LABELS[5]="R1"
      BTN_LABELS[6]="L2"; BTN_LABELS[7]="R2"
      BTN_LABELS[8]="Select"; BTN_LABELS[9]="Start"
      BTN_LABELS[10]="PS"
      BTN_LABELS[11]="L3"; BTN_LABELS[12]="R3"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 8 9 10 11 12)
      DPAD_MODE="axes"; DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    nintendo)
      BTN_LABELS[0]="B"; BTN_LABELS[1]="A"; BTN_LABELS[2]="Y"; BTN_LABELS[3]="X"
      BTN_LABELS[4]="L"; BTN_LABELS[5]="R"
      BTN_LABELS[6]="-"; BTN_LABELS[7]="+"
      BTN_LABELS[8]="L3"; BTN_LABELS[9]="R3"
      BTN_LABELS[10]="Home"; BTN_LABELS[11]="Capture"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 8 9 10 11)
      DPAD_MODE="axes"; DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    fightstick)
      BTN_LABELS[0]="P1"; BTN_LABELS[1]="P2"; BTN_LABELS[2]="P3"; BTN_LABELS[3]="P4"
      BTN_LABELS[4]="P5"; BTN_LABELS[5]="P6"
      BTN_LABELS[6]="Select/Coin"; BTN_LABELS[7]="Start"
      BTN_LABELS[10]="Home/Guide"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 10)
      ;;
  esac
}

# -------------------------
# Calibración (opcional)
# -------------------------
prompt_choice() {
  local prompt="$1" def="$2" ans=""
  if is_tty; then
    read -r -p "$prompt" ans || ans="$def"
    ans="${ans:-$def}"
  else
    ans="$def"
  fi
  echo "$ans"
}
pause_if_tty() { is_tty && read -r -p "Presiona Enter para continuar..." _ || true; }

wait_button_press_timeout() {
  local dev="$1" timeout_s="${2:-12}"
  coproc JS { stdbuf -oL jstest --event "$dev" 2>/dev/null; }
  local end=$((SECONDS + timeout_s))
  local line type num val out=""
  while (( SECONDS < end )); do
    if IFS= read -r -t 0.1 line <&"${JS[0]}"; then
      type="$(sed -n 's/.*type \([0-9]\+\).*/\1/p' <<<"$line")"
      num="$(sed -n 's/.*number \([0-9]\+\).*/\1/p' <<<"$line")"
      val="$(sed -n 's/.*value \(-\{0,1\}[0-9]\+\).*/\1/p' <<<"$line")"
      if [[ "$type" == "1" && "$val" == "1" && -n "${num:-}" ]]; then out="$num"; break; fi
    fi
  done
  # shellcheck disable=SC1083  # {JS[0]} es la sintaxis de bash para cerrar el fd del coproc
  exec {JS[0]}<&- 2>/dev/null || true
  kill "${JS_PID:-0}" 2>/dev/null || true
  wait "${JS_PID:-0}" 2>/dev/null || true
  [[ -n "$out" ]] && { echo "$out"; return 0; }
  return 1
}

wait_dpad_trigger_timeout() {
  local dev="$1" timeout_s="${2:-3}"
  coproc JS { stdbuf -oL jstest --event "$dev" 2>/dev/null; }
  local end=$((SECONDS + timeout_s))
  local line type num val out=""
  while (( SECONDS < end )); do
    if IFS= read -r -t 0.1 line <&"${JS[0]}"; then
      type="$(sed -n 's/.*type \([0-9]\+\).*/\1/p' <<<"$line")"
      num="$(sed -n 's/.*number \([0-9]\+\).*/\1/p' <<<"$line")"
      val="$(sed -n 's/.*value \(-\{0,1\}[0-9]\+\).*/\1/p' <<<"$line")"
      [[ -z "${type:-}" || -z "${num:-}" || -z "${val:-}" ]] && continue
      if [[ "$type" == "2" ]]; then
        local a; a="$(abs_i "$val")"
        if (( val != 0 )) && ( (( a >= 25000 )) || (( a <= 1 )) ); then out="axis:${num}:${val}"; break; fi
      elif [[ "$type" == "1" && "$val" == "1" ]]; then
        out="btn:${num}"; break
      fi
    fi
  done
  # shellcheck disable=SC1083  # {JS[0]} es la sintaxis de bash para cerrar el fd del coproc
  exec {JS[0]}<&- 2>/dev/null || true
  kill "${JS_PID:-0}" 2>/dev/null || true
  wait "${JS_PID:-0}" 2>/dev/null || true
  [[ -n "$out" ]] && { echo "$out"; return 0; }
  return 1
}

calibration_prompts_for_profile() {
  case "$1" in
    xbox) echo "A B X Y LB RB View Menu Share L3 R3 Guide" ;;
    sony) echo "✕ ○ □ △ L1 R1 Share Options L3 R3 PS Touchpad" ;;
    ps3)  echo "✕ ○ □ △ L1 R1 L2 R2 Select Start PS L3 R3" ;;
    nintendo) echo "B A Y X L R - + L3 R3 Home Capture" ;;
    fightstick) echo "P1 P2 P3 P4 P5 P6 Select/Coin Start Home/Guide" ;;
    *) echo "" ;;
  esac
}

calibrate_profile() {
  local dev="$1" vidpid="$2" p="$3"
  local f; f="$(map_file_for "$vidpid" "$p")"
  local prompts; prompts="$(calibration_prompts_for_profile "$p")"
  [[ -n "$prompts" ]] || return 0

  tput cup 0 0 2>/dev/null || true
  tput ed 2>/dev/null || true
  echo "=== CALIBRACIÓN ==="
  echo "Control : $vidpid"
  echo "Perfil  : $p"
  echo "Archivo : $f"
  echo
  echo "Si un botón no se detecta en 12s, se salta."
  echo

  declare -A tmp
  local order=()
  for label in $prompts; do
    echo -n "Presiona: [$label] ... "
    if b="$(wait_button_press_timeout "$dev" 12)"; then
      echo "B${b}"
      tmp["$b"]="$label"
      order+=("$b")
    else
      echo "NO detectado (se salta)"
    fi
    sleep 0.10
  done

  echo
  echo "D-Pad: presiona ↑ (3s)..."
  local up_ev rt_ev
  up_ev="$(wait_dpad_trigger_timeout "$dev" 3 || true)"
  if [[ -z "${up_ev:-}" ]]; then
    echo "No vi eventos del D-pad."
    local ans; ans="$(prompt_choice "¿Mapear D-pad como BOTONES? (s/N): " "N")"
    if [[ "${ans,,}" == "s" ]]; then
      echo -n "Presiona D-pad ↑ ... "; DPAD_BTN_UP="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_UP}"
      echo -n "Presiona D-pad ↓ ... "; DPAD_BTN_DOWN="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_DOWN}"
      echo -n "Presiona D-pad ← ... "; DPAD_BTN_LEFT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_LEFT}"
      echo -n "Presiona D-pad → ... "; DPAD_BTN_RIGHT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_RIGHT}"
      DPAD_MODE="buttons"; DPAD_X_AXIS=-1; DPAD_Y_AXIS=-1
    else
      DPAD_MODE="none"
    fi
  else
    echo "Detecté: $up_ev"
    echo "D-Pad: presiona → (3s)..."
    rt_ev="$(wait_dpad_trigger_timeout "$dev" 3 || true)"
    [[ -n "${rt_ev:-}" ]] && echo "Detecté: $rt_ev" || echo "No detecté →"

    if [[ "$up_ev" == axis:* && "${rt_ev:-}" == axis:* ]]; then
      DPAD_MODE="axes"
      DPAD_Y_AXIS="${up_ev#axis:}"; DPAD_Y_AXIS="${DPAD_Y_AXIS%%:*}"
      DPAD_X_AXIS="${rt_ev#axis:}"; DPAD_X_AXIS="${DPAD_X_AXIS%%:*}"
      DPAD_BTN_UP=-1; DPAD_BTN_DOWN=-1; DPAD_BTN_LEFT=-1; DPAD_BTN_RIGHT=-1
    elif [[ "$up_ev" == btn:* ]]; then
      DPAD_MODE="buttons"
      DPAD_BTN_UP="${up_ev#btn:}"
      echo -n "Presiona D-pad ↓ ... "; DPAD_BTN_DOWN="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_DOWN}"
      echo -n "Presiona D-pad ← ... "; DPAD_BTN_LEFT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_LEFT}"
      echo -n "Presiona D-pad → ... "; DPAD_BTN_RIGHT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_RIGHT}"
      DPAD_X_AXIS=-1; DPAD_Y_AXIS=-1
    else
      DPAD_MODE="none"
    fi
  fi

  {
    echo "# Autogenerado por joyviz calibrate"
    echo "declare -gA BTN_LABELS=()"
    for k in "${!tmp[@]}"; do printf 'BTN_LABELS[%s]=%q\n' "$k" "${tmp[$k]}"; done
    echo -n "declare -ga DISPLAY_BUTTONS=("
    for b in "${order[@]}"; do printf "%s " "$b"; done
    echo ")"
    printf 'DPAD_MODE=%q\n' "$DPAD_MODE"
    echo "DPAD_X_AXIS=${DPAD_X_AXIS}"
    echo "DPAD_Y_AXIS=${DPAD_Y_AXIS}"
    echo "DPAD_BTN_UP=${DPAD_BTN_UP}"
    echo "DPAD_BTN_DOWN=${DPAD_BTN_DOWN}"
    echo "DPAD_BTN_LEFT=${DPAD_BTN_LEFT}"
    echo "DPAD_BTN_RIGHT=${DPAD_BTN_RIGHT}"
  } > "$f"

  echo
  echo "✅ Mapeo guardado en: $f"
  pause_if_tty
}

# -------------------------
# Estado / UI
# -------------------------
declare -a BTN AXIS
btn_max=32
axis_max=8
DPAD_STATE="·"
LAST_EVT=""
LAST_EVT_MS=0
__DIRTY=1
__AXIS_DIRTY=0
__LAST_DRAW_MS=0

reset_state() {
  BTN=(); AXIS=()
  btn_max=32; axis_max=8
  for ((i=0;i<btn_max;i++)); do BTN[i]=0; done
  for ((i=0;i<axis_max;i++)); do AXIS[i]=0; done
  DPAD_STATE="·"
LAST_EVT=""
LAST_EVT_MS=0
__DIRTY=1
__AXIS_DIRTY=0
__LAST_DRAW_MS=0
}

label_for_btn() { local i="$1"; [[ -n "${BTN_LABELS[$i]:-}" ]] && printf "%s" "${BTN_LABELS[$i]}" || printf "?"; }

dpad_update() {
  local up=0 down=0 left=0 right=0
  if [[ "$DPAD_MODE" == "axes" && $DPAD_X_AXIS -ge 0 && $DPAD_Y_AXIS -ge 0 ]]; then
    local x="${AXIS[$DPAD_X_AXIS]:-0}" y="${AXIS[$DPAD_Y_AXIS]:-0}"
    (( x < -16000 || (x < 0 && x >= -1) )) && left=1
    (( x >  16000 || (x > 0 && x <=  1) )) && right=1
    (( y < -16000 || (y < 0 && y >= -1) )) && up=1
    (( y >  16000 || (y > 0 && y <=  1) )) && down=1
  elif [[ "$DPAD_MODE" == "buttons" ]]; then
    (( DPAD_BTN_UP    >= 0 )) && [[ "${BTN[$DPAD_BTN_UP]:-0}" == "1" ]] && up=1
    (( DPAD_BTN_DOWN  >= 0 )) && [[ "${BTN[$DPAD_BTN_DOWN]:-0}" == "1" ]] && down=1
    (( DPAD_BTN_LEFT  >= 0 )) && [[ "${BTN[$DPAD_BTN_LEFT]:-0}" == "1" ]] && left=1
    (( DPAD_BTN_RIGHT >= 0 )) && [[ "${BTN[$DPAD_BTN_RIGHT]:-0}" == "1" ]] && right=1
  fi
  local s=""
  ((up)) && s+="↑"; ((down)) && s+="↓"; ((left)) && s+="←"; ((right)) && s+="→"
  [[ -z "$s" ]] && s="·"
  DPAD_STATE="$s"
}

# -------------------------
# Salida por combo (mantener 0.7s)
# -------------------------
btn_index_by_label() {
  local want="$1" i
  for i in "${!BTN_LABELS[@]}"; do [[ "${BTN_LABELS[$i]}" == "$want" ]] && { echo "$i"; return 0; }; done
  echo -1
}
EXIT_HOLD_MS=700
_exit_combo_since_ms=0
now_ms() { date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

eff_profile="xbox"
check_exit_combo() {
  local a b aidx bidx
  case "$eff_profile" in
    xbox) a="Menu"; b="View" ;;
    nintendo) a="+"; b="-" ;;
    *) a="Start"; b="Select" ;;
  esac
  aidx="$(btn_index_by_label "$a")"; bidx="$(btn_index_by_label "$b")"
  (( aidx >= 0 && bidx >= 0 )) || { _exit_combo_since_ms=0; return 0; }
  if [[ "${BTN[$aidx]:-0}" == "1" && "${BTN[$bidx]:-0}" == "1" ]]; then
    local t; t="$(now_ms)"
    if (( _exit_combo_since_ms == 0 )); then _exit_combo_since_ms="$t"
    elif (( t - _exit_combo_since_ms >= EXIT_HOLD_MS )); then cleanup; exit 0; fi
  else
    _exit_combo_since_ms=0
  fi
}

set_last_event() {
  # args: type num val
  local t="$1" n="$2" v="$3"
  local lbl=""
  if [[ "$t" == "btn" ]]; then
    if [[ "$raw_mode" == "1" ]]; then
      lbl="B${n}"
    else
      lbl="$(label_for_btn "$n")"
      lbl="B${n} (${lbl})"
    fi
    LAST_EVT="Botón: ${lbl} -> ${v}"
  else
    LAST_EVT="Eje: A${n} -> ${v}"
  fi
  LAST_EVT_MS="$(now_ms)"
}

render_no_controller() {
  local buf=""
  tput cup 0 0 2>/dev/null || true
  tput ed 2>/dev/null || true

  buf+="joyviz - Sin mandos detectados

"
  buf+="No hay mandos disponibles en /dev/input/js*.
"
  buf+="Conecta un mando (Xbox/PlayStation/Nintendo/Fightstick) y lo detecto automáticamente.

"
  buf+="Tip Mayflash/F500 V2: usa --follow by-path para sobrevivir cambios de modo.

"
  buf+="Ctrl+C para salir.
"
  printf "%b" "$buf"
}

render() {
  local term_cols shown=0 label_w cell_w cols
  term_cols="$(tput cols 2>/dev/null || echo 120)"

  # Clear screen (from home) then print everything in ONE write to reduce tearing
  tput cup 0 0 2>/dev/null || true
  tput ed 2>/dev/null || true

  local buf="" i
  buf+="Dispositivo : ${DEV_NAME} (${DEV_NODE})
"
  buf+="VID:PID     : ${VIDPID}
"
  buf+="Marca       : ${BRAND}
"
  buf+="Modo        : ${MODE}
"
  buf+="Perfil      : ${eff_profile}
"
  buf+="Seguimiento : ${follow}
"
  buf+="Mapeo       : ${MAP_STATUS}
"
  [[ -n "${ANCHOR:-}" ]] && buf+="Ancla       : ${ANCHOR}
"

  # Último evento (se borra después de 1200ms)
  local _now; _now="$(now_ms)"
  if [[ -n "${LAST_EVT:-}" ]] && (( _now - ${LAST_EVT_MS:-0} <= 1200 )); then
    buf+="Último      : ${LAST_EVT}
"
  else
    buf+="Último      : (sin eventos recientes)
"
  fi
  buf+="
"

  buf+="D-Pad: ${DPAD_STATE}   (modo: ${DPAD_MODE})

"
  buf+="Botones (Bxx[Jyy] Label):
"

  local list=()
  if [[ "${raw_mode}" == "1" ]]; then
    for ((i=0;i<btn_max;i++)); do list+=("$i"); done
  else
    if (( ${#DISPLAY_BUTTONS[@]} > 0 )); then
      list=("${DISPLAY_BUTTONS[@]}")
    else
      for ((i=0;i<btn_max;i++)); do list+=("$i"); done
    fi
  fi

  # Cálculo de ancho de label (cap)
  label_w=2
  if [[ "${raw_mode}" != "1" ]]; then
    for i in "${list[@]}"; do
      local l n
      l="$(label_for_btn "$i")"
      # wc -m para multi-byte (aprox). Cap para evitar wrap raro.
      n="$(printf "%s" "$l" | wc -m)"
      (( n > label_w )) && label_w="$n"
    done
  else
    label_w=3
  fi
  (( label_w < 2 )) && label_w=2
  (( label_w > 12 )) && label_w=12

  # Más conservador para evitar wrap por espacios finales
  cell_w=$(( 18 + label_w ))  # reduce 1 vs antes
  cols=$(( (term_cols-1) / (cell_w+1) ))  # +1 por separador
  (( cols < 1 )) && cols=1
  (( cols > 6 )) && cols=6

  shown=0
  for i in "${list[@]}"; do
    local mark=" " j lbl colored cell
    [[ "${BTN[i]:-0}" == "1" ]] && mark="X"
    j=$((i+1))
    if [[ "${raw_mode}" == "1" ]]; then
      lbl="RAW"
      colored="$(printf "%-${label_w}s" "$lbl")"
    else
      lbl="$(label_for_btn "$i")"
      colored="$(colorize_label_padded "${eff_profile}" "$lbl" "$mark" "$label_w")"
    fi

    # Cell sin trailing spaces excesivos (evita wrap)
    cell="$(printf "B%02d[J%02d] (%s) [%s]" "$i" "$j" "$colored" "$mark")"
    buf+=" ${cell} "

    ((shown++))
    if (((shown)%cols==0)); then
      # recorta espacios al final de la línea
      buf="$(printf "%b" "$buf" | sed 's/[[:space:]]\+$//')
"
    fi
  done
  # asegurar newline final
  buf="$(printf "%b" "$buf" | sed 's/[[:space:]]\+$//')

"

  buf+="Ejes:
"
  for ((i=0;i<axis_max;i++)); do
    buf+=" A$(printf "%02d" "$i"):"
    buf+="$(printf "%7s" "${AXIS[i]}")  "
    (((i+1)%4==0)) && buf+="
"
  done
  buf+="
"
  buf+="Ctrl+C para salir. Combo (0.7s): Xbox Menu+View | Nintendo + & - | Sony/PS3 Start+Select
"

  printf "%b" "$buf"
}


# -------------------------
# Inicialización de modo auto
# -------------------------
AUTO=1
if [[ -n "$pick_dev" ]]; then
  AUTO=0
fi

# globals de dispositivo
DEV_NODE=""
DEV_NAME=""
VIDPID=""
BRAND=""
MODE=""
MAP_STATUS=""
ANCHOR=""

declare -A asked_once

init_device() {
  DEV_NODE="$1"
  reset_state

  local base sys vid pid name_lc
  base="$(basename "$DEV_NODE")"
  sys="/sys/class/input/${base}/device"
  DEV_NAME="$DEV_NODE"
  [[ -r "${sys}/name" ]] && DEV_NAME="$(cat "${sys}/name")"
  vid="????"; pid="????"
  [[ -r "${sys}/id/vendor" ]] && vid="$(cat "${sys}/id/vendor")"
  [[ -r "${sys}/id/product" ]] && pid="$(cat "${sys}/id/product")"
  VIDPID="${vid}:${pid}"
  name_lc="${DEV_NAME,,}"

  eff_profile="$profile"
  [[ "$eff_profile" == "auto" ]] && eff_profile="$(guess_profile "$vid" "$pid" "$name_lc")"
  [[ "$eff_profile" == "auto" ]] && eff_profile="xbox"

  BRAND="$(brand_from_vid "$vid")"
  MODE="$(mode_guess "$vid" "$pid" "$name_lc")"

  set_profile_defaults "$eff_profile"
  local mf; mf="$(map_file_for "$VIDPID" "$eff_profile")"
  MAP_STATUS="sin mapa (fallback)"

  if load_map_if_exists "$mf" >/dev/null 2>&1; then
    MAP_STATUS="OK (calibrado)"
  else
    if [[ "$raw_mode" == "1" ]]; then
      MAP_STATUS="RAW (sin labels)"
    elif [[ "$no_auto_cal" == "1" ]]; then
      MAP_STATUS="sin mapa (auto-cal desactivado)"
    else
      if [[ "$force_auto_cal" == "1" ]]; then
        calibrate_profile "$DEV_NODE" "$VIDPID" "$eff_profile"
        load_map_if_exists "$mf" >/dev/null 2>&1 && MAP_STATUS="OK (calibrado)" || MAP_STATUS="sin mapa (fallback)"
      else
        # preguntar una vez por VIDPID+perfil
        local key="${VIDPID}.${eff_profile}"
        if [[ -z "${asked_once[$key]:-}" && $(is_tty; echo $?) -eq 0 ]]; then
          asked_once[$key]=1
          tput cup 0 0 2>/dev/null || true
  tput ed 2>/dev/null || true
          echo "Detecté un control NUEVO (sin mapeo guardado):"
          echo "  Nombre : $DEV_NAME"
          echo "  VID:PID: $VIDPID"
          echo "  Perfil : $eff_profile"
          echo
          echo "Elige:"
          echo "  [C] Calibrar ahora (recomendado)"
          echo "  [S] Saltar"
          echo "  [R] RAW (solo Bxx/Axx)"
          echo
          local ans; ans="$(prompt_choice "Opción (C/S/R) [C]: " "C")"
          case "${ans^^}" in
            C)
              calibrate_profile "$DEV_NODE" "$VIDPID" "$eff_profile"
              load_map_if_exists "$mf" >/dev/null 2>&1 && MAP_STATUS="OK (calibrado)" || MAP_STATUS="sin mapa (fallback)"
              ;;
            S) MAP_STATUS="sin mapa (fallback)" ;;
            R) raw_mode="1"; MAP_STATUS="RAW (sin labels)" ;;
          esac
        fi
      fi
    fi
  fi

  # seguimiento/anchor
  if [[ "$follow" == "auto" ]]; then
    ANCHOR="$(find_anchor_link "$DEV_NODE" || true)"
    if [[ -n "$ANCHOR" ]]; then
      [[ "$ANCHOR" == /dev/input/by-path/* ]] && follow="by-path" || follow="by-id"
    else
      follow="direct"
    fi
  elif [[ "$follow" == "by-path" || "$follow" == "by-id" ]]; then
    ANCHOR="$(find_anchor_link "$DEV_NODE" || true)"
    [[ -z "$ANCHOR" ]] && follow="direct"
  else
    ANCHOR=""
  fi

  dpad_update
}

# -------------------------
# Loop principal
# -------------------------
CURRENT=""
while true; do
  local_dev=""

  if (( AUTO == 1 )); then
    if ! local_dev="$(auto_pick_js)" || [[ -z "$local_dev" ]]; then
      render_no_controller
      __LAST_DRAW_MS="$(now_ms)"
      sleep 0.25
      continue
    fi
  else
    local_dev="$pick_dev"
    while [[ ! -e "$local_dev" ]]; do
      render_no_controller
      echo
      echo "Esperando el dispositivo indicado: $local_dev"
      sleep 0.25
    done
  fi

  # si tenemos anchor (follow by-path/by-id), usamos el real de ese anchor
  if [[ "$follow" != "direct" && -n "${ANCHOR:-}" ]]; then
    if [[ -e "$ANCHOR" ]]; then
      _r="$(resolve_real "$ANCHOR")"
      [[ -n "$_r" && -e "$_r" ]] && local_dev="$_r"
    fi
  fi

  # si cambia dispositivo, re-inicializa
  if [[ "$local_dev" != "$CURRENT" ]]; then
    CURRENT="$local_dev"
    init_device "$CURRENT"
    __LAST_DRAW_MS="$(now_ms)"
    render
  fi

  # lectura de eventos; si se desconecta, jstest termina y volvemos arriba
  while IFS= read -r line; do
    type="$(sed -n 's/.*type \([0-9]\+\).*/\1/p' <<<"$line")"
    num="$(sed -n 's/.*number \([0-9]\+\).*/\1/p' <<<"$line")"
    val="$(sed -n 's/.*value \(-\{0,1\}[0-9]\+\).*/\1/p' <<<"$line")"
    [[ -z "${type:-}" || -z "${num:-}" || -z "${val:-}" ]] && continue

    if [[ "$type" == "1" ]]; then
      if (( num >= btn_max )); then
        old=$btn_max; btn_max=$((num+1))
        for ((i=old;i<btn_max;i++)); do BTN[i]=0; done
      fi
      BTN[$num]=$(( val != 0 ? 1 : 0 ))
    elif [[ "$type" == "2" ]]; then
      if (( num >= axis_max )); then
        old=$axis_max; axis_max=$((num+1))
        for ((i=old;i<axis_max;i++)); do AXIS[i]=0; done
      fi
      AXIS[$num]="$val"
    fi

    dpad_update
    check_exit_combo

    # Registrar último evento y marcar "dirty"
    _t_now="$(now_ms)"
    if [[ "$type" == "1" ]]; then
      set_last_event btn "$num" "$val"
      __DIRTY=1
    elif [[ "$type" == "2" ]]; then
      set_last_event axis "$num" "$val"
      __AXIS_DIRTY=1
    fi

    # Redibujo:
    # - botones: inmediato
    # - ejes: en lote cada ~120ms para bajar flicker
    if (( __DIRTY == 1 )); then
      __DIRTY=0
      __AXIS_DIRTY=0
      __LAST_DRAW_MS="$_t_now"
      render
    elif (( __AXIS_DIRTY == 1 )) && (( _t_now - ${__LAST_DRAW_MS:-0} >= 120 )); then
      __AXIS_DIRTY=0
      __LAST_DRAW_MS="$_t_now"
      render
    fi
  done < <(stdbuf -oL jstest --event "$CURRENT" 2>/dev/null)

  # si llegamos aquí, probablemente se desconectó
  CURRENT=""
  sleep 0.2
done
