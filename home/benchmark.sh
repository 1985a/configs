#!/usr/bin/env bash
# scx-bench.sh — Diagnóstico + Bench multi-run (NORMAL vs GAMING) para scxctl + amd_pstate_epp
set -u
export LC_ALL=C

SCRIPT_NAME="scx-bench.sh"

# ---- colores (si hay TTY) ----
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'
  C_BAD=$'\033[1;31m'
  C_INFO=$'\033[1;36m'
  C_DIM=$'\033[2m'
else
  C_RESET=""; C_BOLD=""; C_OK=""; C_WARN=""; C_BAD=""; C_INFO=""; C_DIM=""
fi

ok()   { printf "%sOK%s  %s\n"   "$C_OK"   "$C_RESET" "$*"; }
warn() { printf "%sWARN%s %s\n"  "$C_WARN" "$C_RESET" "$*"; }
bad()  { printf "%sMAL%s  %s\n"  "$C_BAD"  "$C_RESET" "$*"; }
info() { printf "%s..%s  %s\n"   "$C_INFO" "$C_RESET" "$*"; }
hdr()  { printf "\n%s== %s ==%s\n" "$C_BOLD" "$*" "$C_RESET"; }

have() { command -v "$1" >/dev/null 2>&1; }
is_num(){ [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }
read_first() { [[ -r "$1" ]] && cat "$1" 2>/dev/null | head -n1 || true; }

uniq_values() {
  local f
  for f in "$@"; do [[ -r "$f" ]] && cat "$f" 2>/dev/null; done \
    | awk 'NF{print}' | sort -u
}

# ---- snapshot/restore sysfs (por path) ----
SNAP_FILE=""
snapshot_sysfs() {
  SNAP_FILE="$(mktemp -t scxbench.snap.XXXXXX)"
  local f
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -r "$f" ]] || continue
    printf "%s=%s\n" "$f" "$(cat "$f" 2>/dev/null | tr -d '\n')" >>"$SNAP_FILE"
  done
  for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [[ -r "$f" ]] || continue
    printf "%s=%s\n" "$f" "$(cat "$f" 2>/dev/null | tr -d '\n')" >>"$SNAP_FILE"
  done
  if have powerprofilesctl; then
    printf "PPD_PROFILE=%s\n" "$(powerprofilesctl get 2>/dev/null | tr -d '\n')" >>"$SNAP_FILE"
  fi
  if have scxctl; then
    printf "SCX_STATE=%s\n" "$(scxctl get 2>/dev/null | head -n1 | tr -d '\n')" >>"$SNAP_FILE"
  fi
}

restore_sysfs() {
  [[ -n "${SNAP_FILE:-}" && -r "$SNAP_FILE" ]] || return 0
  hdr "Restaurando estado original (gob/EPP/PPD/SCX)…"

  local line key val
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"

    case "$key" in
      /sys/devices/system/cpu/*/cpufreq/scaling_governor|/sys/devices/system/cpu/*/cpufreq/energy_performance_preference)
        echo "$val" | sudo tee "$key" >/dev/null 2>&1 || true
        ;;
      PPD_PROFILE)
        if have powerprofilesctl && [[ -n "$val" && "$val" != "NA" ]]; then
          powerprofilesctl set "$val" >/dev/null 2>&1 || true
        fi
        ;;
      SCX_STATE)
        if have scxctl; then
          if echo "$val" | grep -qi "Bpf.*Auto"; then
            scxctl switch -s bpfland -m auto >/dev/null 2>&1 || true
          elif echo "$val" | grep -qi "Bpf.*Gaming"; then
            scxctl switch -s bpfland -m gaming >/dev/null 2>&1 || true
          fi
        fi
        ;;
    esac
  done <"$SNAP_FILE"

  rm -f "$SNAP_FILE" 2>/dev/null || true
}

trap 'restore_sysfs' EXIT INT TERM

# ---- estado CPU ----
cpu_driver() { read_first /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver; }
gov_avail()  { read_first /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; }
epp_avail()  { read_first /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_available_preferences; }
gov_all_uniq(){ uniq_values /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; }
epp_all_uniq(){ uniq_values /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; }

service_state_user(){ systemctl --user is-active "$1" 2>/dev/null || echo "inactive"; }
service_state_sys(){ systemctl is-active "$1" 2>/dev/null || echo "inactive"; }

scx_state() {
  have scxctl || { echo "scxctl: not-installed"; return; }
  scxctl get 2>/dev/null | head -n1 | sed 's/[[:space:]]\+$//'
}

# ---- setters sysfs ----
set_all_sysfs() {
  local glob="$1" val="$2" f
  for f in $glob; do
    [[ -e "$f" ]] || continue
    echo "$val" | sudo tee "$f" >/dev/null 2>&1 || true
  done
}

pick_epp_normal() {
  local avail; avail="$(epp_avail)"
  if echo "$avail" | grep -qw balance_power; then echo "balance_power"
  elif echo "$avail" | grep -qw power; then echo "power"
  elif echo "$avail" | grep -qw default; then echo "default"
  else echo ""
  fi
}

apply_normal() {
  hdr "Aplicando NORMAL"
  have scxctl && { info "scxctl: bpfland/auto"; scxctl switch -s bpfland -m auto >/dev/null 2>&1 || true; }
  if have powerprofilesctl; then info "powerprofilesctl: balanced"; powerprofilesctl set balanced >/dev/null 2>&1 || true; fi
  info "cpufreq governor: powersave"
  set_all_sysfs "/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" "powersave"

  local eppn; eppn="$(pick_epp_normal)"
  if [[ -n "$eppn" ]] && compgen -G "/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference" >/dev/null; then
    info "EPP: $eppn"
    set_all_sysfs "/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference" "$eppn"
  fi
}

apply_gaming() {
  hdr "Aplicando GAMING"
  have scxctl && { info "scxctl: bpfland/gaming"; scxctl switch -s bpfland -m gaming >/dev/null 2>&1 || true; }
  if have powerprofilesctl; then info "powerprofilesctl: performance"; powerprofilesctl set performance >/dev/null 2>&1 || true; fi
  info "cpufreq governor: performance"
  set_all_sysfs "/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" "performance"
  if compgen -G "/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference" >/dev/null; then
    info "EPP: performance"
    set_all_sysfs "/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference" "performance"
  fi
}

# ---- stress-ng parsing ----
run_stress_switch() {
  local out sw_usr
  out="$(stress-ng --switch 0 --timeout 30s --metrics-brief 2>&1 || true)"
  sw_usr="$(echo "$out" | awk '
    / metrc: .* switch[[:space:]]/ {
      for(i=NF;i>=1;i--){
        if($i ~ /^[0-9]+([.][0-9]+)?$/){ print $i; exit }
      }
    }')"
  [[ -n "${sw_usr:-}" ]] || sw_usr="NA"
  echo "$sw_usr"
}

run_stress_cyclic() {
  local out mean maxv p99 p999
  out="$(sudo stress-ng --cyclic 1 --cyclic-policy fifo --cyclic-prio 80 --cyclic-dist 1 --timeout 15s --metrics-brief 2>&1 || true)"

  mean="$(echo "$out" | awk '
    /cyclic: .*mean:/ {
      for(i=1;i<=NF;i++){
        if($i=="mean:"){ if((i+1)<=NF){ print $(i+1); exit } }
      }
    }')"

  maxv="$(echo "$out" | awk '
    /cyclic: .*min:/ && /max:/ {
      for(i=1;i<=NF;i++){
        if($i=="max:"){ if((i+1)<=NF){ gsub(/,/, "", $(i+1)); print $(i+1); exit } }
      }
    }')"

  p99="$(echo "$out" | awk '
    /cyclic: .*99\.00%:/ {
      for(i=1;i<=NF;i++){
        if($i ~ /^99\.00%:$/){ if((i+1)<=NF){ print $(i+1); exit } }
      }
    }')"

  # Preferimos 99.9 para estabilidad
  p999="$(echo "$out" | awk '
    /cyclic: .*99\.90%:/ {
      for(i=1;i<=NF;i++){
        if($i ~ /^99\.90%:$/){ if((i+1)<=NF){ print $(i+1); exit } }
      }
    }
    /cyclic: .*99\.9%:/ {
      for(i=1;i<=NF;i++){
        if($i ~ /^99\.9+%:$/){ if((i+1)<=NF){ print $(i+1); exit } }
      }
    }')"

  is_num "${mean:-}" || mean="NA"
  is_num "${maxv:-}" || maxv="NA"
  is_num "${p99:-}"  || p99="NA"
  is_num "${p999:-}" || p999="NA"

  echo "$mean $p99 $p999 $maxv"
}

# ---- mejora (%): positivo = mejor ----
impr_latency() {
  local b="$1" a="$2"
  [[ "$b" == "NA" || "$a" == "NA" ]] && { echo "NA"; return; }
  awk -v b="$b" -v a="$a" 'BEGIN{
    if(b<=0){print "NA"; exit}
    printf "%.1f", ((b-a)/b)*100.0
  }'
}
impr_throughput() {
  local b="$1" a="$2"
  [[ "$b" == "NA" || "$a" == "NA" ]] && { echo "NA"; return; }
  awk -v b="$b" -v a="$a" 'BEGIN{
    if(b<=0){print "NA"; exit}
    printf "%.1f", ((a-b)/b)*100.0
  }'
}

# ---- tabla color + umbrales ----
TH_GOOD="1.0"   # >= 1% mejora clara
TH_NEAR="0.5"   # |x| < 0.5 casi igual

classify() {
  local v="$1"
  [[ "$v" == "NA" ]] && { echo "na"; return; }
  awk -v v="$v" -v g="$TH_GOOD" -v n="$TH_NEAR" 'BEGIN{
    if(v>=g) print "good";
    else if(v<=-g) print "bad";
    else if(v>-n && v<n) print "near";
    else if(v>0) print "good"; else print "bad";
  }'
}

fmt_impr_colored() {
  local v="$1" cls sign
  if [[ "$v" == "NA" ]]; then
    printf "%s~NA%%%s" "$C_WARN" "$C_RESET"
    return
  fi
  sign="$(awk -v v="$v" 'BEGIN{ if(v>0) print "+"; else print "" }')"
  cls="$(classify "$v")"
  case "$cls" in
    good) printf "%s~%s%s%%%s" "$C_OK" "$sign" "$v" "$C_RESET" ;;
    near) printf "%s~%s%s%%%s" "$C_WARN" "$sign" "$v" "$C_RESET" ;;
    bad)  printf "%s~%s%s%%%s" "$C_BAD" "$sign" "$v" "$C_RESET" ;;
    *)    printf "%s~%s%s%%%s" "$C_WARN" "$sign" "$v" "$C_RESET" ;;
  esac
}

row() {
  local name="$1" b="$2" a="$3" iv="$4"
  printf "%-14s %12s %12s %12s\n" "$name" "$b" "$a" "$(fmt_impr_colored "$iv")"
}

# ---- mediana robusta (ignora NA) ----
median_vals() {
  local tmp n a b
  tmp="$(mktemp -t scxbench.med.XXXXXX)"
  for v in "$@"; do is_num "$v" && printf "%s\n" "$v" >>"$tmp"; done
  n="$(wc -l <"$tmp" | tr -d ' ')"
  if [[ -z "$n" || "$n" -eq 0 ]]; then rm -f "$tmp" 2>/dev/null || true; echo "NA"; return; fi
  sort -n "$tmp" -o "$tmp"
  if (( n % 2 == 1 )); then
    sed -n "$(( (n+1)/2 ))p" "$tmp"
  else
    a="$(sed -n "$(( n/2 ))p" "$tmp")"
    b="$(sed -n "$(( n/2 + 1 ))p" "$tmp")"
    awk -v a="$a" -v b="$b" 'BEGIN{printf "%.2f",(a+b)/2.0}'
  fi
  rm -f "$tmp" 2>/dev/null || true
}

# ---- min/max/range (ignora NA) ----
minmax_vals() {
  # output: "min max" o "NA NA"
  local tmp n
  tmp="$(mktemp -t scxbench.mm.XXXXXX)"
  for v in "$@"; do is_num "$v" && printf "%s\n" "$v" >>"$tmp"; done
  n="$(wc -l <"$tmp" | tr -d ' ')"
  if [[ -z "$n" || "$n" -eq 0 ]]; then rm -f "$tmp" 2>/dev/null || true; echo "NA NA"; return; fi
  sort -n "$tmp" -o "$tmp"
  printf "%s %s\n" "$(head -n1 "$tmp")" "$(tail -n1 "$tmp")"
  rm -f "$tmp" 2>/dev/null || true
}

range_vals() {
  local mn mx
  read -r mn mx < <(minmax_vals "$@")
  [[ "$mn" == "NA" || "$mx" == "NA" ]] && { echo "NA"; return; }
  awk -v mn="$mn" -v mx="$mx" 'BEGIN{ printf "%.2f", (mx-mn) }'
}

range_pct_vs_median() {
  local med="$1" rng="$2"
  [[ "$med" == "NA" || "$rng" == "NA" ]] && { echo "NA"; return; }
  awk -v m="$med" -v r="$rng" 'BEGIN{ if(m<=0){print "NA"; exit} printf "%.1f", (r/m)*100.0 }'
}

# ---- color para estabilidad: menor rango% = mejor ----
stability_color() {
  # inputs: nrngp grngp -> output colored text "GAMING mejor/peor/igual"
  local n="$1" g="$2"
  if [[ "$n" == "NA" || "$g" == "NA" ]]; then
    printf "%sNA%s" "$C_WARN" "$C_RESET"
    return
  fi
  awk -v n="$n" -v g="$g" 'BEGIN{
    # margen 10% relativo para considerar "similar"
    if(g <= n*0.90) print "better";
    else if(g >= n*1.10) print "worse";
    else print "similar";
  }' | while read -r r; do
    case "$r" in
      better)  printf "%sGAMING más estable%s" "$C_OK" "$C_RESET" ;;
      worse)   printf "%sGAMING menos estable%s" "$C_BAD" "$C_RESET" ;;
      similar) printf "%sSimilar%s" "$C_WARN" "$C_RESET" ;;
    esac
  done
}

status_block() {
  hdr "CPU / Energía / SCX"
  printf "Driver:   %s\n" "$(cpu_driver)"
  printf "Gov avail:%s\n" " $(gov_avail)"
  printf "EPP avail:%s\n" " $(epp_avail)"
  printf "Gov uniq: %s\n" "$(gov_all_uniq | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
  printf "EPP uniq: %s\n" "$(epp_all_uniq | tr '\n' ' ' | sed 's/[[:space:]]\+$//')"
  printf "PPD:      %s\n" "$(have powerprofilesctl && powerprofilesctl get 2>/dev/null || echo NA)"
  printf "SCX:      %s\n" "$(scx_state)"

  hdr "Servicios que pueden pelearse con esto"
  printf "gamemoded(user):         %s\n" "$(service_state_user gamemoded.service)"
  printf "scx-autogame(user):      %s\n" "$(service_state_user scx-autogame.service)"
  printf "power-profiles-daemon:   %s\n" "$(service_state_sys power-profiles-daemon.service)"
  printf "tlp:                     %s\n" "$(service_state_sys tlp.service)"
  printf "auto-cpufreq:            %s\n" "$(service_state_sys auto-cpufreq.service)"
  printf "ananicy/ananicy-cpp:     %s %s\n" "$(service_state_sys ananicy.service)" "$(service_state_sys ananicy-cpp.service)"

  hdr "Chequeo rápido (lo que debería pasar)"
  local govc; govc="$(gov_all_uniq | wc -l | awk '{print $1}')"
  [[ "$govc" == "1" ]] && ok "Governor homogéneo: $(gov_all_uniq)" || bad "Governor NO homogéneo: $(gov_all_uniq | tr '\n' ' ')"

  if compgen -G "/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference" >/dev/null; then
    local eppc; eppc="$(epp_all_uniq | wc -l | awk '{print $1}')"
    [[ "$eppc" == "1" ]] && ok "EPP visible: $(epp_all_uniq)" || warn "EPP NO homogéneo: $(epp_all_uniq | tr '\n' ' ')"
  else
    warn "EPP no existe (normal si tu driver no lo expone)"
  fi

  [[ "$(service_state_sys power-profiles-daemon.service)" == "active" ]] && warn "power-profiles-daemon está activo: puede re-escribir governor/EPP según el perfil"
}

bench() {
  local runs="${1:-3}"
  [[ "$runs" =~ ^[0-9]+$ ]] || runs=3
  (( runs < 1 )) && runs=1

  hdr "BENCH: NORMAL (before) vs GAMING (after)"
  warn "Tip: para resultados limpios: cierra Brave/overlays y NO muevas el mouse durante cyclic."
  warn "Este bench corre ${runs} veces y usa MEDIANA para una comparación más confiable."
  warn "Cambia perfiles TEMPORALMENTE y los restaura SOLO al final."

  snapshot_sysfs

  if [[ "$(service_state_sys ananicy.service)" == "active" || "$(service_state_sys ananicy-cpp.service)" == "active" ]]; then
    warn "Deteniendo ananicy temporalmente (reduce interferencias)…"
    sudo systemctl stop ananicy.service 2>/dev/null || true
    sudo systemctl stop ananicy-cpp.service 2>/dev/null || true
  fi

  declare -a N_mean N_p99 N_p999 N_max N_sw
  declare -a G_mean G_p99 G_p999 G_max G_sw

  # -------------------------
  # FASE 1: NORMAL (N corridas)
  # -------------------------
  apply_normal
  hdr "FASE NORMAL: ${runs} corridas (sin cambiar perfil entre corridas)"
  local i
  for ((i=1; i<=runs; i++)); do
    hdr "NORMAL — Corrida $i/$runs"
    info "Corriendo cyclic (NORMAL)…"
    read -r 'N_mean[i]' 'N_p99[i]' 'N_p999[i]' 'N_max[i]' < <(run_stress_cyclic)
    info "Corriendo switch (NORMAL)…"
    N_sw[i]="$(run_stress_switch)"
    sleep 1
  done

  # -------------------------
  # FASE 2: GAMING (N corridas)
  # -------------------------
  apply_gaming
  hdr "FASE GAMING: ${runs} corridas (sin cambiar perfil entre corridas)"
  for ((i=1; i<=runs; i++)); do
    hdr "GAMING — Corrida $i/$runs"
    info "Corriendo cyclic (GAMING)…"
    read -r 'G_mean[i]' 'G_p99[i]' 'G_p999[i]' 'G_max[i]' < <(run_stress_cyclic)
    info "Corriendo switch (GAMING)…"
    G_sw[i]="$(run_stress_switch)"
    sleep 1
  done

  # ----------------------------------------
  # RESULTADOS por corrida (emparejado por i)
  # ----------------------------------------
  hdr "Resultados por corrida (NORMAL vs GAMING)"
  for ((i=1; i<=runs; i++)); do
    local I_mean I_p99 I_p999 I_max I_sw
    I_mean="$(impr_latency "${N_mean[i]}" "${G_mean[i]}")"
    I_p99="$(impr_latency  "${N_p99[i]}"  "${G_p99[i]}")"
    I_p999="$(impr_latency "${N_p999[i]}" "${G_p999[i]}")"
    I_max="$(impr_latency  "${N_max[i]}"  "${G_max[i]}")"
    I_sw="$(impr_throughput "${N_sw[i]}"  "${G_sw[i]}")"

    printf "%s%sCorrida %d/%d%s\n" "$C_BOLD" "$C_INFO" "$i" "$runs" "$C_RESET"
    printf "%s%-14s %12s %12s %12s%s\n" "$C_DIM" "metric" "before" "after" "improvement" "$C_RESET"
    printf "%s%-14s %12s %12s %12s%s\n" "$C_DIM" "--------------" "------------" "------------" "------------" "$C_RESET"
    row "cy_mean(ns)"   "${N_mean[i]}" "${G_mean[i]}" "$I_mean"
    row "cy_p99(ns)"    "${N_p99[i]}"  "${G_p99[i]}"  "$I_p99"
    row "cy_p99.9(ns)"  "${N_p999[i]}" "${G_p999[i]}" "$I_p999"
    row "cy_max(ns)"    "${N_max[i]}"  "${G_max[i]}"  "$I_max"
    row "sw_ops/s"      "${N_sw[i]}"   "${G_sw[i]}"   "$I_sw"
    echo
  done

  # ---- resumen robusto con medianas ----
  hdr "Resumen robusto (MEDIANA de $runs corridas)"
  local MN_mean MN_p99 MN_p999 MN_max MN_sw
  local MG_mean MG_p99 MG_p999 MG_max MG_sw

  MN_mean="$(median_vals "${N_mean[@]:1}")"
  MN_p99="$(median_vals  "${N_p99[@]:1}")"
  MN_p999="$(median_vals "${N_p999[@]:1}")"
  MN_max="$(median_vals  "${N_max[@]:1}")"
  MN_sw="$(median_vals   "${N_sw[@]:1}")"

  MG_mean="$(median_vals "${G_mean[@]:1}")"
  MG_p99="$(median_vals  "${G_p99[@]:1}")"
  MG_p999="$(median_vals "${G_p999[@]:1}")"
  MG_max="$(median_vals  "${G_max[@]:1}")"
  MG_sw="$(median_vals   "${G_sw[@]:1}")"

  local I_mean I_p99 I_p999 I_max I_sw
  I_mean="$(impr_latency "$MN_mean" "$MG_mean")"
  I_p99="$(impr_latency  "$MN_p99"  "$MG_p99")"
  I_p999="$(impr_latency "$MN_p999" "$MG_p999")"
  I_max="$(impr_latency  "$MN_max"  "$MG_max")"
  I_sw="$(impr_throughput "$MN_sw"  "$MG_sw")"

  printf "%-14s %12s %12s %12s\n" "metric" "before" "after" "improvement"
  printf "%-14s %12s %12s %12s\n" "--------------" "------------" "------------" "------------"
  row "cy_mean(ns)"   "$MN_mean" "$MG_mean" "$I_mean"
  row "cy_p99(ns)"    "$MN_p99"  "$MG_p99"  "$I_p99"
  row "cy_p99.9(ns)"  "$MN_p999" "$MG_p999" "$I_p999"
  row "cy_max(ns)"    "$MN_max"  "$MG_max"  "$I_max"
  row "sw_ops/s"      "$MN_sw"   "$MG_sw"   "$I_sw"

  # ---- CONSISTENCIA / VARIACIÓN ----
  hdr "Consistencia / Variación entre corridas (mientras más bajo el rango%, más estable)"
  local nmn nmx gmn gmx nrng grng nrngp grngp
  printf "%-14s %12s %12s %12s %12s   %12s %12s %12s %12s   %s\n" \
    "metric" "N_min" "N_med" "N_max" "N_rng%" "G_min" "G_med" "G_max" "G_rng%" "estabilidad"
  printf "%-14s %12s %12s %12s %12s   %12s %12s %12s %12s   %s\n" \
    "--------------" "------------" "------------" "------------" "------------" \
    "------------" "------------" "------------" "------------" "----------"

  _cons_row() {
    local name="$1" nmed="$2" gmed="$3"; shift 3
    local -a narr=("${!1}"); local -a garr=("${!2}")

    read -r nmn nmx < <(minmax_vals "${narr[@]:1}")
    read -r gmn gmx < <(minmax_vals "${garr[@]:1}")

    nrng="$(range_vals "${narr[@]:1}")"
    grng="$(range_vals "${garr[@]:1}")"

    nrngp="$(range_pct_vs_median "$nmed" "$nrng")"
    grngp="$(range_pct_vs_median "$gmed" "$grng")"

    _rngpct_color() {
      local v="$1"
      [[ "$v" == "NA" ]] && { printf "%sNA%s" "$C_WARN" "$C_RESET"; return; }
      awk -v v="$v" 'BEGIN{
        if(v<=3) print "g";
        else if(v<=8) print "y";
        else print "r";
      }' | while read -r c; do
        case "$c" in
          g) printf "%s%0.1f%%%s" "$C_OK" "$v" "$C_RESET" ;;
          y) printf "%s%0.1f%%%s" "$C_WARN" "$v" "$C_RESET" ;;
          r) printf "%s%0.1f%%%s" "$C_BAD" "$v" "$C_RESET" ;;
        esac
      done
    }

    printf "%-14s %12s %12s %12s %12s   %12s %12s %12s %12s   %s\n" \
      "$name" "$nmn" "$nmed" "$nmx" "$(_rngpct_color "$nrngp")" \
      "$gmn" "$gmed" "$gmx" "$(_rngpct_color "$grngp")" "$(stability_color "$nrngp" "$grngp")"
  }

  _cons_row "cy_mean(ns)"  "$MN_mean" "$MG_mean" N_mean[@]  G_mean[@]
  _cons_row "cy_p99(ns)"   "$MN_p99"  "$MG_p99"  N_p99[@]   G_p99[@]
  _cons_row "cy_p99.9(ns)" "$MN_p999" "$MG_p999" N_p999[@]  G_p999[@]
  _cons_row "cy_max(ns)"   "$MN_max"  "$MG_max"  N_max[@]   G_max[@]
  _cons_row "sw_ops/s"     "$MN_sw"   "$MG_sw"   N_sw[@]    G_sw[@]

  # ---- Diagnóstico final ----
  hdr "Diagnóstico (basado en MEDIANAS)"
  local good=0 badc=0 near=0 na=0
  local v
  for v in "$I_mean" "$I_p99" "$I_p999" "$I_max" "$I_sw"; do
    case "$(classify "$v")" in
      good) ((good++)) ;;
      bad)  ((badc++)) ;;
      near) ((near++)) ;;
      na)   ((na++)) ;;
    esac
  done

  if [[ "$badc" -eq 0 && "$good" -ge 2 ]]; then
    ok "Con $runs corridas, GAMING se ve favorable en general (más mejoras que pérdidas)."
  elif [[ "$good" -eq 0 && "$badc" -ge 2 ]]; then
    bad "Con $runs corridas, GAMING empeora jitter/latencia en general: mejor quédate en NORMAL."
  else
    warn "Resultado mixto: GAMING ayuda en unas métricas y empeora en otras (basado en medianas)."
  fi

  if [[ "$(service_state_sys power-profiles-daemon.service)" == "active" ]]; then
    warn "power-profiles-daemon está activo: puede sobreescribir governor/EPP mientras juegas."
    info "Si quieres control total, prueba desactivar/masquear PPD o fija tu política con él."
  fi

  echo
  info "Si ves WATCHDOG/task stall en journal: prueba desde TTY sin compositor (Sway/KDE fuera)."
  # restore_sysfs() lo hace el trap SOLO al salir del script.
}

usage() {
  cat <<EOF
${SCRIPT_NAME} — Bench SCX/PPD/CPUfreq con comparación robusta y consistencia

Uso:
  ./${SCRIPT_NAME} status
  ./${SCRIPT_NAME} bench              # corre 3 veces (default)
  ./${SCRIPT_NAME} bench 5            # corre 5 veces
  ./${SCRIPT_NAME} --help | -h | --?  # ayuda

Qué hace:
  - Toma snapshot del estado actual (SCX / powerprofilesctl / governors / EPP)
  - Ejecuta NORMAL vs GAMING por N corridas (default 3)
  - Compara usando MEDIANA (menos sensible a outliers)
  - Muestra:
      * Mejora (%) por métricas
      * Consistencia: min/med/max y rango% entre corridas
  - Restaura tu estado original al final (incluso si lo cancelas con Ctrl+C)

Tips:
  - Cierra Brave/Steam overlay y NO muevas el mouse durante cyclic
  - Si sale WATCHDOG/task stall en journal: prueba desde TTY sin compositor

EOF
}

main() {
  local cmd="${1:-status}"

  case "$cmd" in
    -h|--help|--h|--\?|-\?|-- ) usage; exit 0 ;;
    status) status_block ;;
    bench)  bench "${2:-3}" ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"

