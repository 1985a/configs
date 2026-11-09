#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# scx_bench.sh  -  Bench NORMAL vs GAMING (SCX + cpufreq + EPP)
# ============================================================

SCRIPT_NAME="$(basename "$0")"

# ---------- Defaults ----------
MODE="status"               # status | bench
RUNS=3
SOFT=0
NO_COLOR=0

CYCLIC_SECS=15
SWITCH_SECS=30
CYCLIC_PRIO=80
CYCLIC_POLICY="fifo"
CYCLIC_DIST=1

NORMAL_GOV="powersave"
GAMING_GOV="performance"

NORMAL_EPP=""   # auto
GAMING_EPP=""   # auto

NORMAL_SCX_MODE="auto"
GAMING_SCX_MODE="gaming"

# ---------- Colors ----------
if [[ -t 1 && $NO_COLOR -eq 0 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_DIM=""; C_BOLD=""
fi

info()  { echo "${C_CYAN}..${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}WARN${C_RESET} $*"; }
ok()    { echo "${C_GREEN}OK${C_RESET}  $*"; }
bad()   { echo "${C_RED}MAL${C_RESET} $*"; }
hdr()   { echo "${C_BOLD}$*${C_RESET}"; }
die()   { echo "${C_RED}ERROR${C_RESET} $*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} - Bench NORMAL (before) vs GAMING (after) con SCX + cpufreq + EPP

USO:
  ${SCRIPT_NAME} --status
  ${SCRIPT_NAME} --bench [--runs N] [--soft]
  ${SCRIPT_NAME} --help | --h | --?

MODOS:
  --status         Solo lectura (NO cambia nada, NO restaura nada, NO levanta servicios)
  --bench          Ejecuta el bench. Detiene servicios conflictivos (hard) y restaura al final.

OPCIONES:
  --runs N         Número de corridas (default: 3). NO restaura entre corridas, solo al final.
  --soft           En --bench: NO detiene servicios; solo advierte.
  --no-color       Desactiva colores ANSI.
  --cyclic-secs N  Segundos para stress-ng --cyclic (default: 15)
  --switch-secs N  Segundos para stress-ng --switch (default: 30)

NOTAS:
  - Para resultados limpios: cierra Brave/Steam overlays y NO muevas el mouse durante cyclic.
  - Si ves WATCHDOG/task stall en journal: correr desde TTY sin compositor.
EOF
}

# ---------- Arg parsing ----------
if [[ $# -eq 0 ]]; then MODE="status"; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) MODE="status"; shift ;;
    --bench)  MODE="bench"; shift ;;
    --runs)   RUNS="${2:-}"; [[ "$RUNS" =~ ^[0-9]+$ ]] || die "--runs requiere número"; shift 2 ;;
    --soft)   SOFT=1; shift ;;
    --no-color) NO_COLOR=1; shift ;;
    --cyclic-secs) CYCLIC_SECS="${2:-}"; [[ "$CYCLIC_SECS" =~ ^[0-9]+$ ]] || die "--cyclic-secs requiere número"; shift 2 ;;
    --switch-secs) SWITCH_SECS="${2:-}"; [[ "$SWITCH_SECS" =~ ^[0-9]+$ ]] || die "--switch-secs requiere número"; shift 2 ;;
    --help|--h|--\?) usage; exit 0 ;;
    *) die "Argumento desconocido: $1 (usa --help)" ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1; }

if [[ "$MODE" == "bench" ]]; then
  need_cmd stress-ng || die "No encuentro 'stress-ng'. Instálalo y vuelve a correr."
fi

# ---------- Sysfs helpers ----------
cpu_paths() { ls -1d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sort -V; }
read_avail_govs() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo ""; }
read_avail_epps() { cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_available_preferences 2>/dev/null || echo ""; }

pick_epp() {
  local want_list="$1" avail="$2" w
  for w in $want_list; do
    if grep -qw "$w" <<<"$avail"; then echo "$w"; return 0; fi
  done
  awk '{print $1}' <<<"$avail" | head -n1
}

# ---------- Bogomips ----------
bogomips_avg() {
  # Promedio de bogomips de /proc/cpuinfo. No siempre cambia, pero lo reportamos.
  awk -F: '
    BEGIN{sum=0;n=0}
    tolower($1) ~ /bogomips/ { gsub(/^[ \t]+/,"",$2); sum += $2; n++ }
    END{ if(n==0) print "NA"; else printf "%.2f", sum/n }
  ' /proc/cpuinfo 2>/dev/null || echo "NA"
}

# ---------- systemd unit inspection WITHOUT side effects ----------
unit_show() {
  local scope="$1" unit="$2"
  local out=""
  if [[ "$scope" == "user" ]]; then
    out="$(systemctl --user show "$unit" -p LoadState -p ActiveState -p SubState 2>/dev/null || true)"
  else
    out="$(systemctl show "$unit" -p LoadState -p ActiveState -p SubState 2>/dev/null || true)"
  fi

  local load active sub
  load="$(grep -m1 '^LoadState=' <<<"$out" | cut -d= -f2 || true)"
  active="$(grep -m1 '^ActiveState=' <<<"$out" | cut -d= -f2 || true)"
  sub="$(grep -m1 '^SubState=' <<<"$out" | cut -d= -f2 || true)"

  [[ -n "$load" ]] || load="not-found"
  [[ -n "$active" ]] || active="inactive"
  [[ -n "$sub" ]] || sub="dead"

  echo "$load|$active|$sub"
}

is_unit_active() {
  local scope="$1" unit="$2"
  local r active
  r="$(unit_show "$scope" "$unit")"
  active="${r#*|}"; active="${active%%|*}"
  [[ "$active" == "active" ]]
}

unit_exists() {
  local scope="$1" unit="$2"
  local r load
  r="$(unit_show "$scope" "$unit")"
  load="${r%%|*}"
  [[ "$load" != "not-found" ]]
}

SYSTEM_UNITS=(
  "ananicy.service"
  "ananicy-cpp.service"
  "auto-cpufreq.service"
  "tlp.service"
  "power-profiles-daemon.service"
  "gamemoded.service"
)
USER_UNITS=(
  "gamemoded.service"
  "scx-autogame.service"
  "scx-autogame@.service"
)

declare -A ORIG_SYS_ACTIVE=()
declare -A ORIG_USER_ACTIVE=()

TMPDIR="$(mktemp -d)"
cleanup_tmp() { rm -rf "$TMPDIR"; }
trap cleanup_tmp EXIT

save_cpu_state() {
  local f="$TMPDIR/cpu_state.tsv"
  : > "$f"
  for cpu in $(cpu_paths); do
    local gov epp
    gov="$(cat "$cpu/cpufreq/scaling_governor" 2>/dev/null || echo "")"
    epp="$(cat "$cpu/cpufreq/energy_performance_preference" 2>/dev/null || echo "")"
    echo -e "$(basename "$cpu")\t$gov\t$epp" >> "$f"
  done
}

restore_cpu_state() {
  local f="$TMPDIR/cpu_state.tsv"
  [[ -f "$f" ]] || return 0

  while IFS=$'\t' read -r cpu_name gov epp; do
    local cpu_dir="/sys/devices/system/cpu/$cpu_name"
    [[ -n "$gov" && -w "$cpu_dir/cpufreq/scaling_governor" ]] && \
      echo "$gov" | sudo tee "$cpu_dir/cpufreq/scaling_governor" >/dev/null || true
    if [[ -n "$epp" && -e "$cpu_dir/cpufreq/energy_performance_preference" ]]; then
      echo "$epp" | sudo tee "$cpu_dir/cpufreq/energy_performance_preference" >/dev/null || true
    fi
  done < "$f"
}

set_all_governor() {
  local gov="$1"
  for cpu in $(cpu_paths); do
    local p="$cpu/cpufreq/scaling_governor"
    [[ -e "$p" ]] || continue
    echo "$gov" | sudo tee "$p" >/dev/null
  done
}

set_all_epp() {
  local epp="$1"
  for cpu in $(cpu_paths); do
    local p="$cpu/cpufreq/energy_performance_preference"
    [[ -e "$p" ]] || continue
    echo "$epp" | sudo tee "$p" >/dev/null
  done
}

# ---------- SCX helpers ----------
scx_get() {
  if need_cmd scxctl; then
    scxctl get 2>/dev/null || true
  else
    echo "scxctl-not-installed"
  fi
}

scx_set_mode() {
  local mode="$1"
  if need_cmd scxctl; then
    scxctl switch -s bpfland -m "$mode" >/dev/null 2>&1 || true
  fi
}

stop_unit() {
  local scope="$1" unit="$2"
  unit_exists "$scope" "$unit" || return 0
  if is_unit_active "$scope" "$unit"; then
    if [[ "$scope" == "user" ]]; then
      systemctl --user stop "$unit" >/dev/null 2>&1 || true
    else
      sudo systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
  fi
}

start_unit() {
  local scope="$1" unit="$2"
  unit_exists "$scope" "$unit" || return 0
  if [[ "$scope" == "user" ]]; then
    systemctl --user start "$unit" >/dev/null 2>&1 || true
  else
    sudo systemctl start "$unit" >/dev/null 2>&1 || true
  fi
}

save_service_states() {
  local u
  for u in "${SYSTEM_UNITS[@]}"; do
    ORIG_SYS_ACTIVE["$u"]=0
    if unit_exists system "$u" && is_unit_active system "$u"; then ORIG_SYS_ACTIVE["$u"]=1; fi
  done
  for u in "${USER_UNITS[@]}"; do
    ORIG_USER_ACTIVE["$u"]=0
    if unit_exists user "$u" && is_unit_active user "$u"; then ORIG_USER_ACTIVE["$u"]=1; fi
  done
}

stop_conflicts() {
  local u
  for u in "${SYSTEM_UNITS[@]}"; do stop_unit system "$u"; done
  for u in "${USER_UNITS[@]}"; do stop_unit user "$u"; done
}

restore_conflicts() {
  local u
  for u in "${!ORIG_SYS_ACTIVE[@]}"; do
    [[ "${ORIG_SYS_ACTIVE[$u]}" -eq 1 ]] && start_unit system "$u"
  done
  for u in "${!ORIG_USER_ACTIVE[@]}"; do
    [[ "${ORIG_USER_ACTIVE[$u]}" -eq 1 ]] && start_unit user "$u"
  done
}

# ---------- Status output ----------
print_cpu_status() {
  hdr "== CPU / Energía / SCX (solo lectura) =="
  local driver govs epps scx
  driver="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")"
  govs="$(read_avail_govs)"
  epps="$(read_avail_epps)"
  scx="$(scx_get)"

  echo "Driver:    $driver"
  echo "Gov avail: ${govs:-"(no info)"}"
  echo "EPP avail: ${epps:-"(no EPP)"}"

  local gov0 epp0
  gov0="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")"
  epp0="$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null || echo "")"
  echo "Gov cpu0:  ${gov0:-"(no)"}"
  echo "EPP cpu0:  ${epp0:-"(no)"}"

  if [[ "$scx" == "scxctl-not-installed" ]]; then
    echo "SCX:       scxctl no instalado"
  else
    local line
    line="$(grep -m1 -E 'running|no scx' <<<"$scx" || true)"
    echo "SCX:       ${line:-"(sin info)"}"
  fi

  echo "Bogomips:  $(bogomips_avg)"
}

print_services_status() {
  hdr ""
  hdr "== Servicios conflictivos (modo suave) =="

  printf "%-30s %-10s %-10s %-10s\n" "unit" "LoadState" "ActiveState" "SubState"
  printf "%-30s %-10s %-10s %-10s\n" "----" "---------" "----------" "--------"

  local any_bad=0

  show_one() {
    local scope="$1" unit="$2"
    local r load active sub
    r="$(unit_show "$scope" "$unit")"
    load="${r%%|*}"
    active="${r#*|}"; active="${active%%|*}"
    sub="${r##*|}"

    local active_color="$C_YELLOW"
    local note="ok"
    if [[ "$load" == "not-found" ]]; then
      active_color="$C_DIM"
      active="inactive"
      sub="dead"
      note="not-found"
    elif [[ "$active" == "active" ]]; then
      active_color="$C_RED"
      note="PUEDE AFECTAR"
      any_bad=1
    else
      active_color="$C_GREEN"
      note="ok"
    fi

    printf "%-30s %-10s %b%-10s%b %-10s\n" "$unit" "$load" "$active_color" "$active" "$C_RESET" "$sub"
    printf "  -> %b%s%b\n" \
      "$([[ "$note" == "PUEDE AFECTAR" ]] && echo "$C_RED" || echo "$C_DIM")" \
      "$note" "$C_RESET"
  }

  for u in "${SYSTEM_UNITS[@]}"; do show_one "system" "$u"; done
  for u in "${USER_UNITS[@]}"; do show_one "user" "$u"; done

  echo
  if [[ $any_bad -eq 1 ]]; then
    warn "Hay servicios activos que pueden ensuciar el bench. En --bench (hard) se detienen automáticamente."
  else
    ok "No veo servicios conflictivos activos (bien para bench)."
  fi
}

# ---------- stress-ng parsing ----------
normalize_stress() {
  # quita prefijos más comunes, y también [PID] sueltos al inicio
  sed -E '
    s/^stress-ng: (metrc|info): \[[0-9]+\] ?//;
    s/^\[[0-9]+\] ?//;
    s/\r$//
  '
}

extract_ns() {
  # extrae el número antes de "ns" en una línea cualquiera
  sed -E 's/.*: *([0-9.]+) *ns.*/\1/'
}

parse_cyclic_metrics() {
  local text="$1"
  local mean p99 p999 maxv

  mean="$(grep -m1 -E 'cyclic: *mean:' <<<"$text" | sed -E 's/.*mean: *([0-9.]+) *ns.*/\1/' || true)"
  maxv="$(grep -m1 -E 'cyclic: *min:'  <<<"$text" | sed -E 's/.*max: *([0-9.]+) *ns.*/\1/' || true)"

  p99="$(grep -m1 -E 'cyclic: *99\.00%:' <<<"$text" | extract_ns || true)"
  p999="$(grep -m1 -E 'cyclic: *99\.90%:' <<<"$text" | extract_ns || true)"
  [[ -n "$p999" ]] || p999="$(grep -m1 -E 'cyclic: *99\.9%:' <<<"$text" | extract_ns || true)"

  echo "${mean:-NA} ${p99:-NA} ${p999:-NA} ${maxv:-NA}"
}

parse_switch_ops() {
  local text="$1"
  local line
  line="$(awk '$1=="switch" && NF>=6 {print; exit}' <<<"$text" || true)"
  if [[ -n "$line" ]]; then
    awk '{print $6}' <<<"$line"
  else
    echo "NA"
  fi
}

run_cyclic() {
  local secs="$1"
  LC_ALL=C sudo -n true >/dev/null 2>&1 || sudo -v
  LC_ALL=C sudo stress-ng \
    --cyclic 1 \
    --cyclic-policy "$CYCLIC_POLICY" \
    --cyclic-prio "$CYCLIC_PRIO" \
    --cyclic-dist "$CYCLIC_DIST" \
    --timeout "${secs}s" \
    --metrics-brief 2>&1 | normalize_stress
}

run_switch() {
  local secs="$1"
  LC_ALL=C stress-ng --switch 0 --timeout "${secs}s" --metrics-brief 2>&1 | normalize_stress
}

# ---------- Math / aggregation (FIXED: no stdin hang) ----------
avg_of_list() {
  # input: numbers separated by spaces, may include NA
  # IMPORTANT: processes "$*" via <<<, never waits for stdin.
  local s="${*:-NA}"
  awk '
    {
      for(i=1;i<=NF;i++){
        if($i!="NA"){
          # si no es numérico puro, ignóralo
          if($i ~ /^[0-9.]+$/){
            sum += $i; n++
          }
        }
      }
    }
    END{
      if(n==0){print "NA"; exit}
      printf "%.2f", sum/n
    }
  ' <<<"$s"
}

pct_latency() {
  local before="$1" after="$2"
  awk -v b="$before" -v a="$after" 'BEGIN{
    if(b=="NA"||a=="NA"||b==0){print "NA"; exit}
    printf "%.1f", ((b-a)/b)*100
  }'
}

pct_throughput() {
  local before="$1" after="$2"
  awk -v b="$before" -v a="$after" 'BEGIN{
    if(b=="NA"||a=="NA"||b==0){print "NA"; exit}
    printf "%.1f", ((a-b)/b)*100
  }'
}

color_for_pct() {
  # for both: positive good, negative bad
  local p="$1" good_thr="${2:-3}"
  if [[ "$p" == "NA" ]]; then echo "$C_DIM"; return; fi
  awk -v p="$p" -v t="$good_thr" 'BEGIN{
    if(p>=t) print "G";
    else if(p<=-t) print "R";
    else print "Y";
  }' | {
    read -r c
    case "$c" in
      G) echo "$C_GREEN" ;;
      R) echo "$C_RED" ;;
      *) echo "$C_YELLOW" ;;
    esac
  }
}

fmt_pct() {
  local p="$1"
  if [[ "$p" == "NA" ]]; then echo "NA"; else printf "%+.1f%%" "$p"; fi
}

# ---------- Bench apply profiles ----------
apply_normal() {
  info "Aplicando NORMAL: scx=bpfland/${NORMAL_SCX_MODE} + gov=${NORMAL_GOV} + epp=${NORMAL_EPP}"
  scx_set_mode "$NORMAL_SCX_MODE"
  set_all_governor "$NORMAL_GOV"
  [[ -n "$NORMAL_EPP" && "$NORMAL_EPP" != "NA" ]] && set_all_epp "$NORMAL_EPP" || true
}

apply_gaming() {
  info "Aplicando GAMING: scx=bpfland/${GAMING_SCX_MODE} + gov=${GAMING_GOV} + epp=${GAMING_EPP}"
  scx_set_mode "$GAMING_SCX_MODE"
  set_all_governor "$GAMING_GOV"
  [[ -n "$GAMING_EPP" && "$GAMING_EPP" != "NA" ]] && set_all_epp "$GAMING_EPP" || true
}

# ---------- Restore handler ----------
SUDO_KEEPALIVE_PID=""

begin_sudo_keepalive() {
  sudo -v
  ( while true; do sudo -n true >/dev/null 2>&1 || exit 0; sleep 25; done ) &
  SUDO_KEEPALIVE_PID="$!"
}

end_sudo_keepalive() {
  [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
}

restore_everything() {
  hdr ""
  hdr "== Restaurando estado original (governor/EPP + servicios) =="
  restore_cpu_state || true
  restore_conflicts || true
  ok "Restauración final completa."
}

# ---------- BENCH main ----------
bench_main() {
  hdr "== BENCH: NORMAL (before) vs GAMING (after) =="
  warn "Tip: para resultados limpios, cierra Brave/overlays y NO muevas el mouse durante cyclic."
  warn "Este bench cambia perfiles TEMPORALMENTE y los restaura al final."

  begin_sudo_keepalive
  trap 'restore_everything; end_sudo_keepalive' EXIT INT TERM

  # Decide EPP based on availability
  local avail_epp
  avail_epp="$(read_avail_epps)"
  if [[ -n "$avail_epp" ]]; then
    NORMAL_EPP="$(pick_epp "balance_power power default performance" "$avail_epp")"
    GAMING_EPP="$(pick_epp "performance balance_performance default power" "$avail_epp")"
  else
    NORMAL_EPP="NA"
    GAMING_EPP="NA"
  fi

  save_cpu_state
  save_service_states

  if [[ $SOFT -eq 0 ]]; then
    info "Deteniendo servicios conflictivos (hard)..."
    stop_conflicts
  else
    warn "Modo --soft: NO detengo servicios. Esto puede ensuciar los resultados."
  fi

  declare -A BEFORE_LIST=()
  declare -A AFTER_LIST=()

  local run
  for run in $(seq 1 "$RUNS"); do
    hdr ""
    hdr "== Corrida $run / $RUNS =="

    # NORMAL
    hdr ""
    hdr "== Aplicando NORMAL =="
    apply_normal

    info "Corriendo cyclic (NORMAL)..."
    local out_cy_n; out_cy_n="$(run_cyclic "$CYCLIC_SECS")"
    local cy_n; cy_n="$(parse_cyclic_metrics "$out_cy_n")"
    read -r cy_mean_n cy_p99_n cy_p999_n cy_max_n <<<"$cy_n"

    info "Corriendo switch (NORMAL)..."
    local out_sw_n; out_sw_n="$(run_switch "$SWITCH_SECS")"
    local sw_ops_n; sw_ops_n="$(parse_switch_ops "$out_sw_n")"

    local bogo_n; bogo_n="$(bogomips_avg)"

    # GAMING
    hdr ""
    hdr "== Aplicando GAMING =="
    apply_gaming

    info "Corriendo cyclic (GAMING)..."
    local out_cy_g; out_cy_g="$(run_cyclic "$CYCLIC_SECS")"
    local cy_g; cy_g="$(parse_cyclic_metrics "$out_cy_g")"
    read -r cy_mean_g cy_p99_g cy_p999_g cy_max_g <<<"$cy_g"

    info "Corriendo switch (GAMING)..."
    local out_sw_g; out_sw_g="$(run_switch "$SWITCH_SECS")"
    local sw_ops_g; sw_ops_g="$(parse_switch_ops "$out_sw_g")"

    local bogo_g; bogo_g="$(bogomips_avg)"

    # store lists
    BEFORE_LIST["cy_mean"]+="${cy_mean_n} "
    AFTER_LIST["cy_mean"]+="${cy_mean_g} "

    BEFORE_LIST["cy_p99"]+="${cy_p99_n} "
    AFTER_LIST["cy_p99"]+="${cy_p99_g} "

    BEFORE_LIST["cy_p99_9"]+="${cy_p999_n} "
    AFTER_LIST["cy_p99_9"]+="${cy_p999_g} "

    BEFORE_LIST["cy_max"]+="${cy_max_n} "
    AFTER_LIST["cy_max"]+="${cy_max_g} "

    BEFORE_LIST["sw_ops"]+="${sw_ops_n} "
    AFTER_LIST["sw_ops"]+="${sw_ops_g} "

    BEFORE_LIST["bogomips"]+="${bogo_n} "
    AFTER_LIST["bogomips"]+="${bogo_g} "

    hdr ""
    hdr "Resumen corrida $run:"
    echo "  cyclic mean(ns):   $cy_mean_n -> $cy_mean_g"
    echo "  cyclic p99(ns):    $cy_p99_n -> $cy_p99_g"
    echo "  cyclic p99.9(ns):  $cy_p999_n -> $cy_p999_g"
    echo "  cyclic max(ns):    $cy_max_n -> $cy_max_g"
    echo "  switch ops/s:      $sw_ops_n -> $sw_ops_g"
    echo "  bogomips(avg):     $bogo_n -> $bogo_g"
  done

  hdr ""
  hdr "== Resultados (promedio de $RUNS corridas) =="

  local b_mean a_mean b_p99 a_p99 b_p999 a_p999 b_max a_max b_sw a_sw b_bogo a_bogo
  b_mean="$(avg_of_list ${BEFORE_LIST["cy_mean"]:-NA})";     a_mean="$(avg_of_list ${AFTER_LIST["cy_mean"]:-NA})"
  b_p99="$(avg_of_list ${BEFORE_LIST["cy_p99"]:-NA})";      a_p99="$(avg_of_list ${AFTER_LIST["cy_p99"]:-NA})"
  b_p999="$(avg_of_list ${BEFORE_LIST["cy_p99_9"]:-NA})";   a_p999="$(avg_of_list ${AFTER_LIST["cy_p99_9"]:-NA})"
  b_max="$(avg_of_list ${BEFORE_LIST["cy_max"]:-NA})";      a_max="$(avg_of_list ${AFTER_LIST["cy_max"]:-NA})"
  b_sw="$(avg_of_list ${BEFORE_LIST["sw_ops"]:-NA})";       a_sw="$(avg_of_list ${AFTER_LIST["sw_ops"]:-NA})"
  b_bogo="$(avg_of_list ${BEFORE_LIST["bogomips"]:-NA})";   a_bogo="$(avg_of_list ${AFTER_LIST["bogomips"]:-NA})"

  local p_mean p_p99 p_p999 p_max p_sw p_bogo
  p_mean="$(pct_latency "$b_mean" "$a_mean")"
  p_p99="$(pct_latency "$b_p99" "$a_p99")"
  p_p999="$(pct_latency "$b_p999" "$a_p999")"
  p_max="$(pct_latency "$b_max" "$a_max")"
  p_sw="$(pct_throughput "$b_sw" "$a_sw")"
  p_bogo="$(pct_throughput "$b_bogo" "$a_bogo")"

  printf "%-14s %14s %14s %14s\n" "metric" "before" "after" "improvement"
  printf "%-14s %14s %14s %14s\n" "--------------" "--------------" "--------------" "--------------"

  local c
  c="$(color_for_pct "$p_mean" 3)"
  printf "%-14s %14s %14s %b%14s%b\n" "cy_mean(ns)" "$b_mean" "$a_mean" "$c" "$(fmt_pct "$p_mean")" "$C_RESET"

  c="$(color_for_pct "$p_p99" 3)"
  printf "%-14s %14s %14s %b%14s%b\n" "cy_p99(ns)" "$b_p99" "$a_p99" "$c" "$(fmt_pct "$p_p99")" "$C_RESET"

  c="$(color_for_pct "$p_p999" 3)"
  printf "%-14s %14s %14s %b%14s%b\n" "cy_p99.9(ns)" "$b_p999" "$a_p999" "$c" "$(fmt_pct "$p_p999")" "$C_RESET"

  c="$(color_for_pct "$p_max" 3)"
  printf "%-14s %14s %14s %b%14s%b\n" "cy_max(ns)" "$b_max" "$a_max" "$c" "$(fmt_pct "$p_max")" "$C_RESET"

  c="$(color_for_pct "$p_sw" 2)"
  printf "%-14s %14s %14s %b%14s%b\n" "sw_ops/s" "$b_sw" "$a_sw" "$c" "$(fmt_pct "$p_sw")" "$C_RESET"

  c="$(color_for_pct "$p_bogo" 1)"
  printf "%-14s %14s %14s %b%14s%b\n" "bogomips" "$b_bogo" "$a_bogo" "$c" "$(fmt_pct "$p_bogo")" "$C_RESET"

  hdr ""
  hdr "== Diagnóstico =="

  local s=0
  score() {
    local p="$1" thr="${2:-3}"
    awk -v p="$p" -v t="$thr" 'BEGIN{
      if(p=="NA") {print 0; exit}
      if(p>=t) print 1;
      else if(p<=-t) print -1;
      else print 0
    }'
  }
  s=$(( s + $(score "$p_mean" 3) ))
  s=$(( s + $(score "$p_p99" 3) ))
  s=$(( s + $(score "$p_p999" 3) ))
  s=$(( s + $(score "$p_max" 3) ))
  s=$(( s + $(score "$p_sw" 2) ))
  s=$(( s + $(score "$p_bogo" 1) ))

  if [[ $s -ge 3 ]]; then
    ok "GAMING parece mejor en general (mejora clara en varias métricas)."
  elif [[ $s -le -3 ]]; then
    bad "GAMING parece peor en general (empeora claro en varias métricas)."
  else
    warn "Resultado mixto: GAMING ayuda en unas métricas y empeora en otras (o diferencia pequeña)."
  fi

  echo
  echo "Regla rápida:"
  echo "  - En cy_* (ns) más bajo = mejor (latencia)"
  echo "  - En sw_ops/s y bogomips más alto = mejor"
  echo
  echo "Si ves WATCHDOG/task stall en journal: prueba desde TTY sin compositor."

  # Restauración final: la hace el trap EXIT (una sola vez)
}

status_main() {
  print_cpu_status
  print_services_status
}

case "$MODE" in
  status) status_main ;;
  bench)  bench_main ;;
  *) die "Modo inválido" ;;
esac

