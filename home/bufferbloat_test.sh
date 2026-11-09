#!/bin/sh
# bb-qosmate.sh - Bufferbloat lite para OpenWrt (QoSmate-friendly)
# - Ayuda (-h), colores, autodiagnóstico
# - Fallback de targets si 1.1.1.1 no responde
# - Mide ping idle vs ping bajo carga (download/upload)
# - Snapshot tc en WAN real + ifb*

# -------------------- Defaults --------------------
TARGETS_DEFAULT="1.1.1.1 8.8.8.8 9.9.9.9"
TARGETS="${TARGETS:-$TARGETS_DEFAULT}"
DUR="${DUR:-20}"                 # segundos por fase
IDLE_PINGS="${IDLE_PINGS:-30}"
PING_INT="${PING_INT:-0.2}"
WORKERS="${WORKERS:-2}"
DOWN_BYTES="${DOWN_BYTES:-250000000}"  # 250MB
UP_MB="${UP_MB:-40}"             # 40MB por POST (requiere curl)
NO_COLOR=0
VERBOSE=0

DOWN_URL_BASE="https://speed.cloudflare.com/__down"
UP_URL_BASE="https://speed.cloudflare.com/__up"

# -------------------- Helpers --------------------
have() { command -v "$1" >/dev/null 2>&1; }

is_tty() { [ -t 1 ]; }

cinit() {
  if [ "$NO_COLOR" -eq 1 ] || ! is_tty; then
    C0=""; CR=""; CG=""; CY=""; CM=""; CC=""; CW=""
    BOLD=""; DIM=""
  else
    C0="$(printf '\033[0m')"
    CR="$(printf '\033[31m')"
    CG="$(printf '\033[32m')"
    CY="$(printf '\033[33m')"
    CM="$(printf '\033[35m')"
    CC="$(printf '\033[36m')"
    CW="$(printf '\033[37m')"
    BOLD="$(printf '\033[1m')"
    DIM="$(printf '\033[2m')"
  fi
}

ok()   { printf "%s%s✔ %s%s\n" "$CG" "$BOLD" "$*" "$C0"; }
warn() { printf "%s%s⚠ %s%s\n" "$CY" "$BOLD" "$*" "$C0"; }
err()  { printf "%s%s✖ %s%s\n" "$CR" "$BOLD" "$*" "$C0" >&2; }
info() { printf "%s%sℹ %s%s\n" "$CC" "$BOLD" "$*" "$C0"; }

die() { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
bb-qosmate.sh - Bufferbloat test lite para OpenWrt (con QoSmate)

USO:
  bb-qosmate.sh [opciones]

OPCIONES:
  -t "IP1 IP2 ..."   Targets a probar (default: 1.1.1.1 8.8.8.8 9.9.9.9)
  -d SEG            Duración de carga por fase (default: 20)
  -n NUM            Cantidad de pings en idle (default: 30)
  -i SEG            Intervalo de ping (default: 0.2)
  -w NUM            Workers de descarga en paralelo (default: 2)
  -B BYTES          Bytes por request de descarga (default: 250000000)
  -U MB             Tamaño (MB) por request de subida (default: 40) [requiere curl]
  -v                Verbose (muestra más diagnóstico)
  --no-color         Desactiva colores
  -h                Mostrar esta ayuda

EJEMPLOS:
  bb-qosmate.sh
  bb-qosmate.sh -d 30 -w 3
  bb-qosmate.sh -t "8.8.8.8 9.9.9.9" -d 25
  TARGETS="1.1.1.1 8.8.8.8" DUR=30 bb-qosmate.sh

NOTAS:
  - Para mejor precisión: prueba desde PC por cable, sin descargas de fondo.
  - Si el ping a 1.1.1.1 falla, el script prueba targets alternativos automáticamente.
  - QoS (CAKE/FQ_CoDel) a veces vive en ifb*, no necesariamente en br-wan.X.
EOF
}

# -------------------- Arg parsing --------------------
# Busybox ash: getopts no maneja long options, lo hacemos simple:
while [ $# -gt 0 ]; do
  case "$1" in
    -t) TARGETS="$2"; shift 2;;
    -d) DUR="$2"; shift 2;;
    -n) IDLE_PINGS="$2"; shift 2;;
    -i) PING_INT="$2"; shift 2;;
    -w) WORKERS="$2"; shift 2;;
    -B) DOWN_BYTES="$2"; shift 2;;
    -U) UP_MB="$2"; shift 2;;
    -v) VERBOSE=1; shift 1;;
    --no-color) NO_COLOR=1; shift 1;;
    -h|--help) usage; exit 0;;
    *) err "Opción desconocida: $1"; echo; usage; exit 1;;
  esac
done

cinit

# -------------------- Network detection --------------------
get_wan_from_ubus() {
  # Si hay ubus+jsonfilter, es lo más confiable
  if have ubus && have jsonfilter; then
    ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null
    return 0
  fi
  return 1
}

get_default_route_dev() {
  ip route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

get_default_route_gw() {
  ip route show default 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}'
}

qosmate_info() {
  have uci || return 0
  # No asumimos campos exactos: intentamos varios
  en="$(uci -q get qosmate.@qosmate[0].enabled)"
  dn="$(uci -q get qosmate.@qosmate[0].download)"; [ -z "$dn" ] && dn="$(uci -q get qosmate.@qosmate[0].down)"
  up="$(uci -q get qosmate.@qosmate[0].upload)";   [ -z "$up" ] && up="$(uci -q get qosmate.@qosmate[0].up)"
  [ -n "$en$dn$up" ] || return 0
  info "QoSmate (UCI): enabled=${en:-?} down=${dn:-?} up=${up:-?}"
}

# -------------------- tc snapshots --------------------
tc_qdisc_short() {
  dev="$1"
  have tc || return 0
  tc qdisc show dev "$dev" 2>/dev/null | sed 's/^/    /'
}

tc_qdisc_stats_head() {
  dev="$1"
  have tc || return 0
  tc -s qdisc show dev "$dev" 2>/dev/null | sed 's/^/    /' | sed -n '1,60p'
}

list_ifb_devs() {
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | awk '/^ifb[0-9]+/ {print $1}'
}

# -------------------- Ping & grade --------------------
ping_stats() {
  _target="$1"
  _count="$2"
  _interval="$3"

  have ping || return 2

  # BusyBox ping: evita -i decimal y evita -W si no existe
  # Forzar intervalo entero si viene decimal
  case "$_interval" in
    *.*) _interval=1 ;;
  esac

  # Construir comando por compatibilidad
  # -w (deadline) suele existir; si no, no pasa nada porque usamos -c
  if ping -c 1 -w 2 127.0.0.1 >/dev/null 2>&1; then
    out="$(ping -c "$_count" -i "$_interval" -w 60 "$_target" 2>/dev/null)"
  else
    out="$(ping -c "$_count" -i "$_interval" "$_target" 2>/dev/null)"
  fi

  [ -n "$out" ] || return 1

  loss="$(echo "$out" | awk -F',' '/packet loss/ {gsub(/%/,"",$3); gsub(/ /,"",$3); print $3; exit}')"
  avg="$(echo "$out" | sed -n 's/.*=\s*\([0-9.]\+\)\/\([0-9.]\+\)\/\([0-9.]\+\).*/\2/p' | tail -n 1)"
  [ -z "$avg" ] && avg="$(echo "$out" | awk -F'/' '/round-trip|min\/avg|max\/mdev/ {print $2; exit}')"

  [ -n "$avg" ] || return 1
  [ -n "$loss" ] || loss="?"

  echo "$avg $loss"
}



grade_waveform_like() {
  d="$1"
  awk -v d="$d" 'BEGIN{
    if (d < 5) print "A+";
    else if (d < 30) print "A";
    else if (d < 60) print "B";
    else if (d < 200) print "C";
    else if (d < 400) print "D";
    else print "F";
  }'
}

grade_color() {
  # Devuelve el color “más relevante” según el grade
  case "$1" in
    A+|A) echo "$CG" ;;      # verde
    B)    echo "$CC" ;;      # cian (o usa $CB si prefieres azul)
    C)    echo "$CY" ;;      # amarillo
    D)    echo "$CM" ;;      # magenta (tipo “naranja/alerta” visual)
    F)    echo "$CR" ;;      # rojo
    *)    echo "$CW" ;;      # blanco (fallback)
  esac
}

choose_working_target() {
  # Prueba rápida SIN -i (para evitar incompatibilidades BusyBox)
  for t in $TARGETS; do
    if ping -c 1 -w 2 "$t" >/dev/null 2>&1; then
      echo "$t"
      return 0
    fi
  done
  return 1
}

# -------------------- Load generators --------------------
_timeout() {
  if have timeout; then timeout "$@"; return $?
  elif have busybox; then busybox timeout "$@"; return $?
  else return 127
  fi
}

start_download_load() {
  if have curl; then
    cmd="curl -L -s -o /dev/null \"${DOWN_URL_BASE}?bytes=${DOWN_BYTES}\""
  elif have wget; then
    cmd="wget -q -O /dev/null \"${DOWN_URL_BASE}?bytes=${DOWN_BYTES}\""
  else
    die "No encuentro ni curl ni wget. Instala uno: opkg install curl o opkg install wget"
  fi

  _timeout "$DUR"s sh -c "i=0; while :; do i=\$((i+1)); $cmd; done" >/dev/null 2>&1 &
  pids="$!"
  # Workers extra:
  i=2
  while [ "$i" -le "$WORKERS" ]; do
    _timeout "$DUR"s sh -c "i=0; while :; do i=\$((i+1)); $cmd; done" >/dev/null 2>&1 &
    pids="$pids $!"
    i=$((i+1))
  done
  echo "$pids"
}

start_upload_load() {
  have curl || return 2
  _timeout "$DUR"s sh -c '
    while :; do
      dd if=/dev/zero bs=1M count='"$UP_MB"' 2>/dev/null | \
        curl -s -o /dev/null -X POST --data-binary @- "'"$UP_URL_BASE"'";
    done
  ' >/dev/null 2>&1 &
  echo "$!"
}

stop_pids() { for p in "$@"; do kill "$p" >/dev/null 2>&1; done; }

# -------------------- Diagnostics --------------------
diag_connectivity() {
  t="$1"
  gw="$(get_default_route_gw)"
  dev="$(get_default_route_dev)"

  info "Diagnóstico rápido:"
  [ -n "$dev" ] && info "  default dev: $dev" || warn "  no veo default dev"
  [ -n "$gw" ]  && info "  default gw:  $gw"  || warn "  no veo default gw"

  if have ip; then
    if [ -n "$t" ]; then
      info "  ip route get $t:"
      ip route get "$t" 2>/dev/null | sed 's/^/    /'
    fi
  fi

  if [ -n "$gw" ]; then
    if ping_stats "$gw" 3 0.2 >/dev/null; then
      ok "  gateway responde ping"
    else
      warn "  gateway NO responde ping (puede estar bloqueado o hay issue WAN)"
    fi
  fi

  if [ "$VERBOSE" -eq 1 ] && have ubus; then
    info "  ubus wan status (resumen):"
    ubus call network.interface.wan status 2>/dev/null | sed 's/^/    /' | sed -n '1,80p'
  fi
}

# -------------------- MAIN --------------------
echo "${BOLD}== Bufferbloat (OpenWrt + QoSmate) ==${C0}"

WAN_UBUS="$(get_wan_from_ubus 2>/dev/null | head -n1)"
WAN_ROUTE="$(get_default_route_dev)"

# Preferimos dev de ruta default para snapshots (suele ser el egress real).
# Pero mostramos ambos para que tú veas si ubus te dio un bridge.
WAN_DEV="${WAN_ROUTE:-$WAN_UBUS}"

[ -n "$WAN_DEV" ] || die "No pude detectar interfaz WAN (ni por ubus ni por ruta default)."

info "WAN (route dev): ${WAN_ROUTE:-N/A}"
info "WAN (ubus l3):   ${WAN_UBUS:-N/A}"
info "WAN usada para tc: $WAN_DEV"
info "Targets: $TARGETS"
info "DUR=${DUR}s | idle=${IDLE_PINGS} | int=${PING_INT}s | workers=${WORKERS} | down_bytes=${DOWN_BYTES} | up_mb=${UP_MB}"
qosmate_info
echo

echo "${BOLD}--- Snapshot tc (WAN) ANTES ---${C0}"
tc_qdisc_short "$WAN_DEV"
ifb_list="$(list_ifb_devs)"
if [ -n "$ifb_list" ]; then
  echo "${BOLD}--- Snapshot tc (ifb*) ANTES ---${C0}"
  for d in $ifb_list; do
    echo "  ${DIM}${d}${C0}"
    tc_qdisc_short "$d"
  done
fi
echo

# Elegir target que funcione
WORKING_TARGET="$(choose_working_target)"
if [ -z "$WORKING_TARGET" ]; then
  err "No pude hacer ping a ninguno de estos targets: $TARGETS"
  diag_connectivity "1.1.1.1"
  echo
  err "Soluciones típicas:"
  echo "  - Verifica que el router tenga salida a internet (ruta default / gateway)."
  echo "  - Prueba otro target: bb-qosmate.sh -t \"8.8.8.8 9.9.9.9\""
  echo "  - Si 'ping' no existe: opkg update && opkg install iputils-ping"
  exit 2
fi

ok "Target elegido: $WORKING_TARGET"
echo

idle="$(ping_stats "$WORKING_TARGET" "$IDLE_PINGS" "$PING_INT")"
if [ $? -ne 0 ]; then
  err "Falló ping idle a $WORKING_TARGET"
  diag_connectivity "$WORKING_TARGET"
  exit 3
fi

IDLE_AVG="$(echo "$idle" | awk '{print $1}')"
IDLE_LOSS="$(echo "$idle" | awk '{print $2}')"
ok "Idle: avg=${BOLD}${IDLE_AVG}${C0} ms | loss=${IDLE_LOSS}%"
echo

info "Fase descarga: saturando ${DUR}s y midiendo latencia..."
down_pids="$(start_download_load)"
down_count="$(awk -v d="$DUR" -v i="$PING_INT" 'BEGIN{c=int(d/i); if(c<20)c=20; print c}')"
down="$(ping_stats "$WORKING_TARGET" "$down_count" "$PING_INT")"
stop_pids $down_pids

if [ -z "$down" ]; then
  warn "No pude medir ping durante descarga (pero la carga se lanzó)."
  DOWN_AVG="0"; DOWN_LOSS="?"
else
  DOWN_AVG="$(echo "$down" | awk '{print $1}')"
  DOWN_LOSS="$(echo "$down" | awk '{print $2}')"
fi

DOWN_DELTA="$(awk -v a="$IDLE_AVG" -v b="$DOWN_AVG" 'BEGIN{printf "%.2f", (b-a)}')"
ok "Descarga: avg=${BOLD}${DOWN_AVG}${C0} ms | loss=${DOWN_LOSS}% | delta=+${BOLD}${DOWN_DELTA}${C0} ms"
echo

if have curl; then
  info "Fase subida: saturando ${DUR}s y midiendo latencia..."
  up_pid="$(start_upload_load)"
  up="$(ping_stats "$WORKING_TARGET" "$down_count" "$PING_INT")"
  stop_pids "$up_pid"

  UP_AVG="$(echo "$up" | awk '{print $1}')"
  UP_LOSS="$(echo "$up" | awk '{print $2}')"
  UP_DELTA="$(awk -v a="$IDLE_AVG" -v b="$UP_AVG" 'BEGIN{printf "%.2f", (b-a)}')"
  ok "Subida:   avg=${BOLD}${UP_AVG}${C0} ms | loss=${UP_LOSS}% | delta=+${BOLD}${UP_DELTA}${C0} ms"
else
  warn "No hay curl: salto prueba de subida. (opkg install curl)"
  UP_AVG="N/A"; UP_LOSS="N/A"; UP_DELTA=""
fi

echo
if [ -n "$UP_DELTA" ]; then
  WORST_DELTA="$(awk -v d="$DOWN_DELTA" -v u="$UP_DELTA" 'BEGIN{print (d>u)?d:u}')"
else
  WORST_DELTA="$DOWN_DELTA"
fi
GRADE="$(grade_waveform_like "$WORST_DELTA")"

echo "${BOLD}== Resumen ==${C0}"
printf "  Idle avg:    %s ms\n" "$IDLE_AVG"
printf "  Down loaded: %s ms (delta +%s)\n" "$DOWN_AVG" "$DOWN_DELTA"
[ -n "$UP_DELTA" ] && printf "  Up loaded:   %s ms (delta +%s)\n" "$UP_AVG" "$UP_DELTA" || printf "  Up loaded:   N/A\n"
printf "  Peor delta:  +%s ms\n" "$WORST_DELTA"
GC="$(grade_color "$GRADE")"
printf "  Grade:       %s%s%s%s\n" "$GC" "$BOLD" "$GRADE" "$C0"
echo

echo "${BOLD}--- Snapshot tc (WAN) DESPUÉS ---${C0}"
tc_qdisc_short "$WAN_DEV"
if [ -n "$ifb_list" ]; then
  echo "${BOLD}--- Snapshot tc (ifb*) DESPUÉS ---${C0}"
  for d in $ifb_list; do
    echo "  ${DIM}${d}${C0}"
    tc_qdisc_short "$d"
  done
fi
echo

# Consejito basado en lo que vimos
if tc_qdisc_short "$WAN_DEV" | grep -q "noqueue"; then
  warn "En $WAN_DEV se ve noqueue. Eso puede significar que el shaper (CAKE) está en ifb* o que esa no es la interfaz real de egress."
  [ -n "$ifb_list" ] && info "Mira los ifb*: si ahí aparece cake/fq_codel, ese es el que manda."
fi

