#!/usr/bin/env bash
# joyviz.sh - visor de joystick por consola con auto-mapeo persistente y D-pad robusto

# Requerimos bash de verdad
[[ -n "${BASH_VERSION:-}" ]] || { echo "Este script requiere bash. Usa: bash $0"; exit 1; }

set -u
set -o pipefail
shopt -s nullglob

# -------------------------
# Utilidades
# -------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Falta '$1'. En Arch: sudo pacman -S joystick"
    exit 1
  }
}

is_tty() { [[ -t 0 && -t 1 ]]; }

pause_if_tty() {
  if is_tty; then
    read -r -p "Presiona Enter para continuar..." _ || true
  fi
}

prompt_choice() {
  # prompt_choice "Texto" "DEFAULT" -> imprime respuesta
  local prompt="$1" def="$2" ans=""
  if is_tty; then
    read -r -p "$prompt" ans || ans="$def"
    ans="${ans:-$def}"
  else
    ans="$def"
  fi
  echo "$ans"
}

resolve_real() { readlink -f "$1" 2>/dev/null || true; }

abs_i() { local x="$1"; (( x<0 )) && echo $(( -x )) || echo "$x"; }

cleanup() {
  tput cnorm 2>/dev/null || true
  tput sgr0 2>/dev/null || true
  printf "\n"
}

# -------------------------
# Ayuda
# -------------------------
usage() {
  cat <<'EOF'
joyviz.sh - visor de joystick en consola con labels + D-pad + auto-calibración.

Uso:
  joyviz.sh [opciones] [/dev/input/jsX]

Opciones:
  --profile auto|xbox|sony|ps3|nintendo|fightstick
      Fuerza perfil (default: auto)

  --follow auto|direct|by-path|by-id
      “Ancla” el control para sobrevivir re-enumeración/cambio de modo (default: auto)
      Recomendado Mayflash: --follow by-path

  --raw
      Modo RAW: muestra todos los botones/ejes sin labels (ideal para test rápido)

  --no-auto-calibrate
      No preguntar por calibración aunque el control sea nuevo (solo fallback o raw)

  --auto-calibrate
      Si no existe mapeo, entra a calibración automáticamente (sin preguntarte)

  -h, --help
      Muestra esta ayuda

Ejemplos:
  ./joyviz.sh --follow by-path
  ./joyviz.sh --raw
  ./joyviz.sh --profile ps3 --auto-calibrate
EOF
}

# -------------------------
# Dependencias
# -------------------------
need_cmd jstest
need_cmd stdbuf
need_cmd tput
need_cmd readlink

#trap cleanup EXIT INT TERM
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM
tput civis

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
# Selección de device
# -------------------------
choose_device_interactive() {
  mapfile -t devs < <(ls -1 /dev/input/js* 2>/dev/null || true)
  (( ${#devs[@]} > 0 )) || { echo "No veo /dev/input/js*. ¿Mando conectado?"; exit 1; }

  if (( ${#devs[@]} == 1 )); then
    echo "${devs[0]}"; return 0
  fi

  echo "Dispositivos disponibles:"
  local i=0
  for d in "${devs[@]}"; do
    local base name
    base="$(basename "$d")"
    name="(nombre desconocido)"
    [[ -r "/sys/class/input/${base}/device/name" ]] && name="$(cat "/sys/class/input/${base}/device/name")"
    printf "  [%d] %-16s  %s\n" "$i" "$d" "$name"
    ((i++))
  done
  echo
  local idx
  idx="$(prompt_choice "Elige índice: " "0")"
  echo "${devs[$idx]}"
}

find_anchor_link() {
  local js="$1"
  local want
  want="$(resolve_real "$js")"
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

# -------------------------
# Identificación / perfiles
# -------------------------
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

# D-pad puede ser por axes o botones
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
  # si el source falla por algo, NO matamos el script
  # shellcheck disable=SC1090
  if ! source "$f" 2>/dev/null; then
    echo "⚠️  Warning: no pude cargar mapa '$f' (archivo corrupto?)."
    return 1
  fi
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
      DPAD_MODE="axes"
      DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    sony)
      BTN_LABELS[0]="✕"; BTN_LABELS[1]="○"; BTN_LABELS[2]="□"; BTN_LABELS[3]="△"
      BTN_LABELS[4]="L1"; BTN_LABELS[5]="R1"
      BTN_LABELS[6]="Share"; BTN_LABELS[7]="Options"
      BTN_LABELS[8]="L3"; BTN_LABELS[9]="R3"
      BTN_LABELS[10]="PS"; BTN_LABELS[11]="Touchpad"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 8 9 10 11)
      DPAD_MODE="axes"
      DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    ps3)
      BTN_LABELS[0]="✕"; BTN_LABELS[1]="○"; BTN_LABELS[2]="□"; BTN_LABELS[3]="△"
      BTN_LABELS[4]="L1"; BTN_LABELS[5]="R1"
      BTN_LABELS[6]="L2"; BTN_LABELS[7]="R2"
      BTN_LABELS[8]="Select"; BTN_LABELS[9]="Start"
      BTN_LABELS[10]="PS"
      BTN_LABELS[11]="L3"; BTN_LABELS[12]="R3"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 8 9 10 11 12)
      DPAD_MODE="axes"
      DPAD_X_AXIS=6; DPAD_Y_AXIS=7
      ;;
    nintendo)
      BTN_LABELS[0]="B"; BTN_LABELS[1]="A"; BTN_LABELS[2]="Y"; BTN_LABELS[3]="X"
      BTN_LABELS[4]="L"; BTN_LABELS[5]="R"
      BTN_LABELS[6]="-"; BTN_LABELS[7]="+"
      BTN_LABELS[8]="L3"; BTN_LABELS[9]="R3"
      BTN_LABELS[10]="Home"; BTN_LABELS[11]="Capture"
      DISPLAY_BUTTONS=(0 1 2 3 4 5 6 7 8 9 10 11)
      DPAD_MODE="axes"
      DPAD_X_AXIS=6; DPAD_Y_AXIS=7
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
# Captura de eventos (calibración sin pipelines) con timeout
# -------------------------
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
      if [[ "$type" == "1" && "$val" == "1" && -n "$num" ]]; then
        out="$num"; break
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

wait_dpad_trigger_timeout() {
  # Devuelve:
  #   axis:<idx>:<val>  (hat axes)
  #   btn:<idx>         (d-pad como botones)
  local dev="$1" timeout_s="${2:-3}"

  coproc JS { stdbuf -oL jstest --event "$dev" 2>/dev/null; }
  local end=$((SECONDS + timeout_s))
  local line type num val out=""

  while (( SECONDS < end )); do
    if IFS= read -r -t 0.1 line <&"${JS[0]}"; then
      type="$(sed -n 's/.*type \([0-9]\+\).*/\1/p' <<<"$line")"
      num="$(sed -n 's/.*number \([0-9]\+\).*/\1/p' <<<"$line")"
      val="$(sed -n 's/.*value \(-\{0,1\}[0-9]\+\).*/\1/p' <<<"$line")"
      [[ -z "$type" || -z "$num" || -z "$val" ]] && continue

      if [[ "$type" == "2" ]]; then
        local a; a="$(abs_i "$val")"
        if (( val != 0 )) && ( (( a >= 25000 )) || (( a <= 1 )) ); then
          out="axis:${num}:${val}"
          break
        fi
      elif [[ "$type" == "1" && "$val" == "1" ]]; then
        out="btn:${num}"
        break
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
  local p="$1"
  case "$p" in
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

  [[ -n "$prompts" ]] || { echo "No hay calibración definida para perfil: $p"; return 0; }

  tput clear
  echo "=== CALIBRACIÓN ==="
  echo "Control : $vidpid"
  echo "Perfil  : $p"
  echo "Archivo : $f"
  echo
  echo "Si un botón no se detecta en 12s, se salta."
  echo "D-pad: se intenta por axes/hat; si no, puedes mapearlo como botones o saltarlo."
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
  up_ev="$(wait_dpad_trigger_timeout "$dev" 3 || true)"

  if [[ -z "$up_ev" ]]; then
    echo "No vi eventos del D-pad."
    local ans
    ans="$(prompt_choice "¿Mapear D-pad como BOTONES? (s/N): " "N")"
    if [[ "${ans,,}" == "s" ]]; then
      echo -n "Presiona D-pad ↑ ... "; DPAD_BTN_UP="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_UP}"
      echo -n "Presiona D-pad ↓ ... "; DPAD_BTN_DOWN="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_DOWN}"
      echo -n "Presiona D-pad ← ... "; DPAD_BTN_LEFT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_LEFT}"
      echo -n "Presiona D-pad → ... "; DPAD_BTN_RIGHT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_RIGHT}"
      DPAD_MODE="buttons"
      DPAD_X_AXIS=-1; DPAD_Y_AXIS=-1
    else
      DPAD_MODE="none"
    fi
  else
    echo "Detecté: $up_ev"
    echo "D-Pad: presiona → (3s)..."
    rt_ev="$(wait_dpad_trigger_timeout "$dev" 3 || true)"
    [[ -n "$rt_ev" ]] && echo "Detecté: $rt_ev" || echo "No detecté →"

    if [[ "$up_ev" == axis:* && "$rt_ev" == axis:* ]]; then
      DPAD_MODE="axes"
      DPAD_Y_AXIS="${up_ev#axis:}"; DPAD_Y_AXIS="${DPAD_Y_AXIS%%:*}"
      DPAD_X_AXIS="${rt_ev#axis:}"; DPAD_X_AXIS="${DPAD_X_AXIS%%:*}"
      DPAD_BTN_UP=-1; DPAD_BTN_DOWN=-1; DPAD_BTN_LEFT=-1; DPAD_BTN_RIGHT=-1
      echo "OK: D-pad por ejes (X=$DPAD_X_AXIS, Y=$DPAD_Y_AXIS)"
    elif [[ "$up_ev" == btn:* ]]; then
      echo "Tu D-pad parece venir como BOTONES. Mapeo por botones."
      DPAD_MODE="buttons"
      DPAD_BTN_UP="${up_ev#btn:}"
      echo -n "Presiona D-pad ↓ ... "; DPAD_BTN_DOWN="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_DOWN}"
      echo -n "Presiona D-pad ← ... "; DPAD_BTN_LEFT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_LEFT}"
      echo -n "Presiona D-pad → ... "; DPAD_BTN_RIGHT="$(wait_button_press_timeout "$dev" 8 || echo -1)"; echo "B${DPAD_BTN_RIGHT}"
      DPAD_X_AXIS=-1; DPAD_Y_AXIS=-1
    else
      echo "No pude confirmar el modo del D-pad. Se deja en none para evitar errores."
      DPAD_MODE="none"
    fi
  fi

  # Guardar mapa
  {
    echo "# Autogenerado por joyviz calibrate"
    echo "declare -gA BTN_LABELS=()"
    for k in "${!tmp[@]}"; do
      printf 'BTN_LABELS[%s]=%q\n' "$k" "${tmp[$k]}"
    done

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
  return 0
}

# -------------------------
# Estado / UI
# -------------------------
declare -a BTN AXIS
btn_max=32
axis_max=8
DPAD_STATE="·"

reset_state() {
  BTN=(); AXIS=()
  btn_max=32; axis_max=8
  for ((i=0;i<btn_max;i++)); do BTN[i]=0; done
  for ((i=0;i<axis_max;i++)); do AXIS[i]=0; done
  DPAD_STATE="·"
}

label_for_btn() {
  local i="$1"
  [[ -n "${BTN_LABELS[$i]:-}" ]] && printf "%s" "${BTN_LABELS[$i]}" || printf "?"
}

dpad_update() {
  local up=0 down=0 left=0 right=0

  if [[ "$DPAD_MODE" == "axes" && $DPAD_X_AXIS -ge 0 && $DPAD_Y_AXIS -ge 0 ]]; then
    local x="${AXIS[$DPAD_X_AXIS]:-0}"
    local y="${AXIS[$DPAD_Y_AXIS]:-0}"

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
  ((up)) && s+="↑"
  ((down)) && s+="↓"
  ((left)) && s+="←"
  ((right)) && s+="→"
  [[ -z "$s" ]] && s="·"
  DPAD_STATE="$s"
}

render() {
  local dev_name="$1" dev="$2" vidpid="$3" brand="$4" mode="$5" eff_profile="$6" anchor="$7" map_status="$8"
  tput clear
  echo "Dispositivo : $dev_name ($dev)"
  echo "VID:PID     : $vidpid"
  echo "Marca       : $brand"
  echo "Modo        : $mode"
  echo "Perfil      : $eff_profile"
  echo "Seguimiento : $follow"
  echo "Mapeo       : $map_status"
  [[ -n "$anchor" ]] && echo "Ancla       : $anchor"
  echo
  echo "D-Pad: $DPAD_STATE   (modo: $DPAD_MODE)"
  echo

   echo "Botones (Bxx[Jyy] Label):"

  local shown=0
  local list=()
  local term_cols label_w cell_w cols

  term_cols="$(tput cols 2>/dev/null || echo 120)"

  if [[ "$raw_mode" == "1" ]]; then
    for ((i=0;i<btn_max;i++)); do list+=("$i"); done
  else
    if (( ${#DISPLAY_BUTTONS[@]} > 0 )); then
      list=("${DISPLAY_BUTTONS[@]}")
    else
      for ((i=0;i<btn_max;i++)); do list+=("$i"); done
    fi
  fi

  # Calcula el ancho máximo real del label en ESTE control (y lo limita)
  label_w=2
  if [[ "$raw_mode" != "1" ]]; then
    for i in "${list[@]}"; do
      local l
      l="$(label_for_btn "$i")"
      # wc -m cuenta caracteres (mejor para símbolos tipo ✕ ○ □ △)
      local n
      n="$(printf "%s" "$l" | wc -m)"
      (( n > label_w )) && label_w="$n"
    done
  else
    label_w=3
  fi
  (( label_w < 2 )) && label_w=2
  (( label_w > 14 )) && label_w=14   # tope para que no se desmadre

  # Calcula cuántas columnas caben en tu terminal
  # Un “tile” aprox: " B00[J00] (" + label + ") [X]  "  => ~19 + label_w
  cell_w=$(( 19 + label_w ))
  cols=$(( term_cols / cell_w ))
  (( cols < 1 )) && cols=1
  (( cols > 8 )) && cols=8

  for i in "${list[@]}"; do
    local mark=" " j lbl
    [[ "${BTN[i]:-0}" == "1" ]] && mark="X"
    j=$((i+1))

    if [[ "$raw_mode" == "1" ]]; then
      lbl="RAW"
    else
      lbl="$(label_for_btn "$i")"
    fi

    printf " B%02d[J%02d] (%-${label_w}s) [%s]  " "$i" "$j" "$lbl" "$mark"
    ((shown++))
    (((shown)%cols==0)) && printf "\n"
  done

  printf "\n\nEjes:\n"
  for ((i=0;i<axis_max;i++)); do
    printf " A%02d:%7s  " "$i" "${AXIS[i]}"
    (((i+1)%4==0)) && printf "\n"
  done

  echo
  echo "Ctrl+C para salir."
}

# -------------------------
# Setup inicial follow/device
# -------------------------
[[ -z "$pick_dev" ]] && pick_dev="$(choose_device_interactive)"

anchor=""
if [[ "$follow" == "auto" ]]; then
  anchor="$(find_anchor_link "$pick_dev" || true)"
  [[ -z "$anchor" ]] && follow="direct"
elif [[ "$follow" == "by-path" || "$follow" == "by-id" ]]; then
  anchor="$(find_anchor_link "$pick_dev" || true)"
  [[ -z "$anchor" ]] && follow="direct"
fi

# -------------------------
# Loop principal
# -------------------------
declare -A asked_once

current_dev=""
eff_profile=""
map_status=""

while true; do
  dev="$pick_dev"

  if [[ "$follow" != "direct" && -n "$anchor" ]]; then
    while [[ ! -e "$anchor" ]]; do
      tput clear
      echo "Esperando que reaparezca el mando (cambio de modo / reconexión)..."
      echo "Ancla: $anchor"
      sleep 0.25
    done

    dev="$(resolve_real "$anchor")"
    while [[ -z "$dev" || ! -e "$dev" ]]; do
      sleep 0.25
      dev="$(resolve_real "$anchor")"
    done
  fi

  if [[ "$dev" != "$current_dev" ]]; then
    current_dev="$dev"
    reset_state

    base="$(basename "$current_dev")"
    sys="/sys/class/input/${base}/device"
    dev_name="$current_dev"
    [[ -r "${sys}/name" ]] && dev_name="$(cat "${sys}/name")"
    vid="????"; pid="????"
    [[ -r "${sys}/id/vendor" ]] && vid="$(cat "${sys}/id/vendor")"
    [[ -r "${sys}/id/product" ]] && pid="$(cat "${sys}/id/product")"
    vidpid="${vid}:${pid}"
    name_lc="${dev_name,,}"

    eff_profile="$profile"
    [[ "$eff_profile" == "auto" ]] && eff_profile="$(guess_profile "$vid" "$pid" "$name_lc")"
    [[ "$eff_profile" == "auto" ]] && eff_profile="xbox"

    brand="$(brand_from_vid "$vid")"
    mode="$(mode_guess "$vid" "$pid" "$name_lc")"

    # defaults + try load map
    set_profile_defaults "$eff_profile"
    mf="$(map_file_for "$vidpid" "$eff_profile")"
    map_status="sin mapa (fallback)"

    if load_map_if_exists "$mf" >/dev/null 2>&1; then
      map_status="OK (calibrado)"
    else
      # No hay mapa. Si RAW, no molestamos.
      if [[ "$raw_mode" == "1" ]]; then
        map_status="RAW (sin labels)"
      elif [[ "$no_auto_cal" == "1" ]]; then
        map_status="sin mapa (auto-cal desactivado)"
      else
        # Auto calibrate directo
        if [[ "$force_auto_cal" == "1" ]]; then
          calibrate_profile "$current_dev" "$vidpid" "$eff_profile"
          if load_map_if_exists "$mf" >/dev/null 2>&1; then
            map_status="OK (calibrado)"
          else
            map_status="sin mapa (fallback)"
          fi
        else
          # Preguntar una sola vez por VID:PID+perfil (si hay tty)
          key="${vidpid}.${eff_profile}"
          if [[ -z "${asked_once[$key]:-}" ]]; then
            asked_once[$key]=1

            if is_tty; then
              tput clear
              echo "Detecté un control NUEVO (sin mapeo guardado):"
              echo "  Nombre : $dev_name"
              echo "  VID:PID: $vidpid"
              echo "  Perfil : $eff_profile"
              echo
              echo "Elige:"
              echo "  [C] Calibrar ahora (recomendado)"
              echo "  [S] Saltar (labels fallback)"
              echo "  [R] RAW (solo Bxx/Axx para test)"
              echo "  [Q] Salir"
              echo
              ans="$(prompt_choice "Opción (C/S/R/Q) [C]: " "C")"
              case "${ans^^}" in
                C)
                  calibrate_profile "$current_dev" "$vidpid" "$eff_profile"
                  if load_map_if_exists "$mf" >/dev/null 2>&1; then
                    map_status="OK (calibrado)"
                  else
                    map_status="sin mapa (fallback)"
                  fi
                  ;;
                S) map_status="sin mapa (fallback)" ;;
                R) raw_mode="1"; map_status="RAW (sin labels)" ;;
                Q) exit 0 ;;
                *) calibrate_profile "$current_dev" "$vidpid" "$eff_profile" ;;
              esac
            else
              # sin tty: no preguntamos (para que NO se cierre ni se trabe)
              map_status="sin mapa (fallback; no-tty)"
            fi
          fi
        fi
      fi
    fi

    render "$dev_name" "$current_dev" "$vidpid" "$brand" "$mode" "$eff_profile" "$anchor" "$map_status"
  fi

  # Lectura continua del joystick (si se desconecta, jstest termina y el while externo reintenta)
  while IFS= read -r line; do
    type="$(sed -n 's/.*type \([0-9]\+\).*/\1/p' <<<"$line")"
    num="$(sed -n 's/.*number \([0-9]\+\).*/\1/p' <<<"$line")"
    val="$(sed -n 's/.*value \(-\{0,1\}[0-9]\+\).*/\1/p' <<<"$line")"
    [[ -z "${type}" || -z "${num}" || -z "${val}" ]] && continue

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
    render "$(cat "/sys/class/input/$(basename "$current_dev")/device/name" 2>/dev/null || echo "$current_dev")" \
           "$current_dev" \
           "$(cat "/sys/class/input/$(basename "$current_dev")/device/id/vendor" 2>/dev/null || echo "????"):$(cat "/sys/class/input/$(basename "$current_dev")/device/id/product" 2>/dev/null || echo "????")" \
           "$(brand_from_vid "$(cat "/sys/class/input/$(basename "$current_dev")/device/id/vendor" 2>/dev/null || echo "????")")" \
           "$(mode_guess "$(cat "/sys/class/input/$(basename "$current_dev")/device/id/vendor" 2>/dev/null || echo "????")" \
                      "$(cat "/sys/class/input/$(basename "$current_dev")/device/id/product" 2>/dev/null || echo "????")" \
                      "$(cat "/sys/class/input/$(basename "$current_dev")/device/name" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)")" \
           "$eff_profile" \
           "$anchor" \
           "$map_status"
  done < <(stdbuf -oL jstest --event "$current_dev" 2>/dev/null)

  sleep 0.2
done

