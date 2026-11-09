#!/usr/bin/env bash
set -euo pipefail

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Falta '$1'. En Arch: sudo pacman -S joystick"; exit 1; }; }
need_cmd jstest
need_cmd stdbuf
need_cmd tput

pick_dev="${1:-}"

# Listar dispositivos /dev/input/js*
if [[ -z "${pick_dev}" ]]; then
  mapfile -t devs < <(ls -1 /dev/input/js* 2>/dev/null || true)
  if (( ${#devs[@]} == 0 )); then
    echo "No veo /dev/input/js*. ¿El mando está conectado? ¿Cargó el driver?"
    exit 1
  fi

  if (( ${#devs[@]} == 1 )); then
    pick_dev="${devs[0]}"
  else
    echo "Dispositivos disponibles:"
    i=0
    for d in "${devs[@]}"; do
      base="$(basename "$d")"       # js0
      name_file="/sys/class/input/${base}/device/name"
      name="(nombre desconocido)"
      [[ -r "$name_file" ]] && name="$(cat "$name_file")"
      printf "  [%d] %-16s  %s\n" "$i" "$d" "$name"
      ((i++))
    done
    echo
    read -rp "Elige índice: " idx
    pick_dev="${devs[$idx]}"
  fi
fi

if [[ ! -e "$pick_dev" ]]; then
  echo "No existe: $pick_dev"
  exit 1
fi

base="$(basename "$pick_dev")"
name_file="/sys/class/input/${base}/device/name"
dev_name="$pick_dev"
[[ -r "$name_file" ]] && dev_name="$(cat "$name_file")"

# Estado dinámico (crece si aparecen botones/axes con número más alto)
declare -a BTN AXIS
btn_max=32
axis_max=8
for ((i=0;i<btn_max;i++)); do BTN[i]=0; done
for ((i=0;i<axis_max;i++)); do AXIS[i]=0; done

cleanup() {
  tput cnorm 2>/dev/null || true
  tput sgr0  2>/dev/null || true
  printf "\n"
}
trap cleanup EXIT INT TERM

tput civis

render() {
  tput clear
  echo "Dispositivo: $dev_name ($pick_dev)"
  echo "Tip: si el juego te muestra algo como J3/Joy3, presiona ese botón ahora y mira qué Bxx cambia."
  echo "Nota: Linux (jstest) numera botones desde 0. Muchos juegos muestran desde 1."
  echo "      Regla común:  J(n)  ≈  B(n-1)"
  echo
  echo "Botones (Bxx):"
  cols=8
  for ((i=0;i<btn_max;i++)); do
    mark=" "
    [[ "${BTN[i]}" == "1" ]] && mark="X"
    # también muestro el equivalente 1-based (J)
    j=$((i+1))
    printf " B%02d[J%02d]:[%s] " "$i" "$j" "$mark"
    if (((i+1) % cols == 0)); then printf "\n"; fi
  done
  printf "\n\nEjes (Axx):\n"
  for ((i=0;i<axis_max;i++)); do
    printf " A%02d:%7s  " "$i" "${AXIS[i]}"
    if (((i+1) % 4 == 0)); then printf "\n"; fi
  done
  echo
  echo "Ctrl+C para salir."
}

# Primera pinta
render

# Leer eventos y actualizar tablero
stdbuf -oL jstest --event "$pick_dev" 2>/dev/null | while IFS= read -r line; do
  # Espera líneas tipo: "Event: type 1, time 1234, number 0, value 1"
  type="$(sed -n 's/.*type \([0-9]\+\).*/\1/p' <<<"$line")"
  num="$(sed -n 's/.*number \([0-9]\+\).*/\1/p' <<<"$line")"
  val="$(sed -n 's/.*value \(-\{0,1\}[0-9]\+\).*/\1/p' <<<"$line")"

  [[ -z "${type}" || -z "${num}" || -z "${val}" ]] && continue

  if [[ "$type" == "1" ]]; then
    # Botón
    if (( num >= btn_max )); then
      old=$btn_max
      btn_max=$((num+1))
      for ((i=old;i<btn_max;i++)); do BTN[i]=0; done
    fi
    BTN[$num]=$(( val != 0 ? 1 : 0 ))
  elif [[ "$type" == "2" ]]; then
    # Eje
    if (( num >= axis_max )); then
      old=$axis_max
      axis_max=$((num+1))
      for ((i=old;i<axis_max;i++)); do AXIS[i]=0; done
    fi
    AXIS[$num]="$val"
  fi

  render
done

