#!/bin/sh
# irq_tune_dlx36_pro.sh
# Dynalink DL-WRX36 (IPQ807x / 4 cores) - perfil OFICIAL + optimización CABLE (sin tocar Wi-Fi)
# Incluye: factory-reset (por affinity_hint + limpia RPS/XPS), apply-official, apply-opt, status, monitor.
# BusyBox ash compatible. No reinicia servicios. No toca tc/qdisc (no rompe QoSMate).

set -eu

PROG="irq_tune_dlx36_pro"
STATE_DIR="/tmp/${PROG}"
STATE_FILE="${STATE_DIR}/state"
LOCK_FILE="${STATE_DIR}/lock"

log() { logger -t "$PROG" "$*"; echo "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "Ejecuta como root"; }

mkdir_state() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
}

# --- util: CPUs ---
ncpus() {
  awk 'NR==1{c=0; for(i=1;i<=NF;i++) if($i ~ /^CPU[0-9]+$/) c++; print c; exit}' /proc/interrupts 2>/dev/null || echo 4
}

cpu_mask() { # cpu_mask 3 -> 8 (hex)
  c="$1"
  echo $((1 << c)) | awk '{printf "%x\n",$1}'
}

# join masks "2 3" -> "c"
cpus_to_mask() {
  m=0
  for c in "$@"; do
    m=$((m | (1 << c)))
  done
  printf "%x\n" "$m"
}

# --- persist / restore only what THIS script touches ---
save_once() {
  f="$1"
  [ -e "$f" ] || return 0
  mkdir_state
  if ! grep -q "^$f " "$STATE_FILE" 2>/dev/null; then
    v="$(cat "$f" 2>/dev/null || true)"
    printf "%s %s\n" "$f" "$v" >> "$STATE_FILE"
  fi
}

restore_state_only() {
  [ -f "$STATE_FILE" ] || { echo "No hay state guardado."; return 0; }
  while read -r f v; do
    [ -e "$f" ] || continue
    echo "$v" > "$f" 2>/dev/null || true
  done < "$STATE_FILE"
  rm -f "$STATE_FILE"
  log "RESTORE: listo (solo lo que este script tocó)."
}

# --- IRQ helpers ---
irq_ids_by_name() {
  # imprime uno o varios IRQ IDs (sin :) que contengan el patrón exacto
  pat="$1"
  awk -v p="$pat" '$0 ~ p {gsub(":","",$1); print $1}' /proc/interrupts
}

set_irq_mask() {
  irq="$1"
  mask="$2"
  f="/proc/irq/$irq/smp_affinity"
  [ -e "$f" ] || return 0
  save_once "$f"
  echo "$mask" > "$f" 2>/dev/null || true
}

set_affinity_name_cpu() {
  # como el oficial: name -> CPU#
  name="$1"
  cpu="$2"
  mask="$(cpu_mask "$cpu")"
  for irq in $(irq_ids_by_name "$name"); do
    set_irq_mask "$irq" "$mask"
  done
}

# --- RPS/XPS helpers ---
all_netdevs() { ls -1 /sys/class/net 2>/dev/null || true; }

is_wireless_dev() {
  dev="$1"
  # /sys/class/net/$dev/phy80211 existe en muchos builds
  [ -d "/sys/class/net/$dev/wireless" ] && return 0
  [ -d "/sys/class/net/$dev/phy80211" ] && return 0
  # fallback: aparece en /proc/net/wireless
  grep -q "^[[:space:]]*$dev:" /proc/net/wireless 2>/dev/null && return 0
  return 1
}

set_rps_xps_dev() {
  dev="$1"
  rps="$2"
  xps="$3"
  [ -d "/sys/class/net/$dev/queues" ] || return 0

  for q in /sys/class/net/"$dev"/queues/rx-*; do
    [ -e "$q/rps_cpus" ] || continue
    save_once "$q/rps_cpus"
    echo "$rps" > "$q/rps_cpus" 2>/dev/null || true
    # opcional: flow_cnt (suave) si existe
    if [ -e "$q/rps_flow_cnt" ]; then
      save_once "$q/rps_flow_cnt"
      echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
    fi
  done

  for q in /sys/class/net/"$dev"/queues/tx-*; do
    [ -e "$q/xps_cpus" ] || continue
    save_once "$q/xps_cpus"
    echo "$xps" > "$q/xps_cpus" 2>/dev/null || true
  done
}

# detect WAN-ish devices (sin asumir tu naming exacto)
wan_devs_detect() {
  # típicos en tu Dynalink: wan br-wan br-wan.1 ifb-wan (y a veces ifb4wan)
  for d in $(all_netdevs); do
    echo "$d" | grep -Eq '^(wan|br-wan(\..*)?|ifb-wan.*|ifb4wan.*)$' && echo "$d"
  done
}

# --- STATUS / SHOW ---
show_irqs_filtered() {
  pat_re="$1"
  echo "IRQ   mask   hint   name"
  echo "----  -----  -----  -----------------------------"
  # parse /proc/interrupts y para cada línea matching:
  awk -v re="$pat_re" '
    $1 ~ /^[0-9]+:$/ && $0 ~ re {
      irq=$1; sub(":","",irq);
      name=$NF;
      print irq, name
    }
  ' /proc/interrupts | while read -r irq name; do
    f="/proc/irq/$irq/smp_affinity"
    h="/proc/irq/$irq/affinity_hint"
    mask="?"
    hint="?"
    [ -e "$f" ] && mask="$(cat "$f" 2>/dev/null || echo '?')"
    [ -e "$h" ] && hint="$(cat "$h" 2>/dev/null || echo '?')"
    printf "%-4s  %-5s  %-5s  %s\n" "$irq" "$mask" "$hint" "$name"
  done
}

show_rpsxps() {
  echo
  echo "== RPS/XPS (solo mostrando; 0 = apagado) =="
  for dev in $(wan_devs_detect); do
    [ -d "/sys/class/net/$dev/queues" ] || continue
    echo "-- $dev --"
    for q in /sys/class/net/"$dev"/queues/rx-*; do
      [ -e "$q/rps_cpus" ] || continue
      echo "  $(basename "$q") rps=$(cat "$q/rps_cpus" 2>/dev/null)"
    done
    for q in /sys/class/net/"$dev"/queues/tx-*; do
      [ -e "$q/xps_cpus" ] || continue
      echo "  $(basename "$q") xps=$(cat "$q/xps_cpus" 2>/dev/null)"
    done
  done
}

status() {
  echo "== CPU cores detectados: $(ncpus) =="
  echo
  echo "== IRQs CABLE (edma_*) =="
  show_irqs_filtered 'edma_'
  echo
  echo "== IRQs Wi-Fi (ath11k datapath) =="
  show_irqs_filtered '(wbm2host|reo2host|ppdu-end|rxdma2host|host2rxdma|ce[0-9]+)'
  show_rpsxps
  echo
  echo "irqbalance: $(pidof irqbalance >/dev/null 2>&1 && echo ACTIVO || echo no)"
  echo "QoSMate/SQM qdisc: (solo lectura)"
  tc qdisc show 2>/dev/null | grep -E 'cake|fq_codel|ingress|ifb|wan|br-wan' || true
}

# --- FACTORY RESET (limpieza fuerte) ---
factory_reset() {
  mkdir_state
  log "FACTORY: restaurando IRQ affinity usando affinity_hint (si existe) + limpiando RPS/XPS."

  # 1) IRQs: si hay affinity_hint != 0, úsalo como baseline (borra rastros de otros scripts)
  for d in /proc/irq/[0-9]*; do
    [ -d "$d" ] || continue
    irq="$(basename "$d")"
    f="$d/smp_affinity"
    h="$d/affinity_hint"
    [ -e "$f" ] || continue
    [ -e "$h" ] || continue
    hint="$(cat "$h" 2>/dev/null || echo 0)"
    # si hint es 0 o vacío, no tocamos
    [ -n "$hint" ] || continue
    echo "$hint" | grep -Eq '^(0|00+)$' && continue
    save_once "$f"
    echo "$hint" > "$f" 2>/dev/null || true
  done

  # 2) RPS/XPS: poner a 0 en TODOS los netdevs (esto sí limpia “rastros”)
  for dev in $(all_netdevs); do
    [ -d "/sys/class/net/$dev/queues" ] || continue
    for q in /sys/class/net/"$dev"/queues/rx-*; do
      [ -e "$q/rps_cpus" ] || continue
      save_once "$q/rps_cpus"
      echo 0 > "$q/rps_cpus" 2>/dev/null || true
      if [ -e "$q/rps_flow_cnt" ]; then
        save_once "$q/rps_flow_cnt"
        echo 0 > "$q/rps_flow_cnt" 2>/dev/null || true
      fi
    done
    for q in /sys/class/net/"$dev"/queues/tx-*; do
      [ -e "$q/xps_cpus" ] || continue
      save_once "$q/xps_cpus"
      echo 0 > "$q/xps_cpus" 2>/dev/null || true
    done
  done

  log "FACTORY: listo."
}

# --- OFICIAL OpenWrt (IPQ807x) ---
apply_official() {
  log "OFICIAL: aplicando afinidad según OpenWrt smp_affinity (IPQ807x)."
  # Igual que el oficial: :contentReference[oaicite:1]{index=1}

  # 4 RX rings -> core 0..3
  set_affinity_name_cpu 'reo2host-destination-ring1' 0
  set_affinity_name_cpu 'reo2host-destination-ring2' 1
  set_affinity_name_cpu 'reo2host-destination-ring3' 2
  set_affinity_name_cpu 'reo2host-destination-ring4' 3

  # 3 TCL completions -> cores 1..3
  set_affinity_name_cpu 'wbm2host-tx-completions-ring1' 1
  set_affinity_name_cpu 'wbm2host-tx-completions-ring2' 2
  set_affinity_name_cpu 'wbm2host-tx-completions-ring3' 3

  # 3 PPDU -> cores 1..3
  set_affinity_name_cpu 'ppdu-end-interrupts-mac1' 1
  set_affinity_name_cpu 'ppdu-end-interrupts-mac2' 2
  set_affinity_name_cpu 'ppdu-end-interrupts-mac3' 3

  # EDMA (LAN/WAN) -> core 3
  set_affinity_name_cpu 'edma_txcmpl' 3
  set_affinity_name_cpu 'edma_rxfill' 3
  set_affinity_name_cpu 'edma_rxdesc' 3
  set_affinity_name_cpu 'edma_misc'   3

  log "OFICIAL: listo."
}

# --- OPTIMIZACIÓN CABLE (no tocar Wi-Fi) ---
apply_opt_cable() {
  # enfoque “seguro”: primero oficial, luego SOLO cable:
  # - split edma: rxfill+txcmpl -> CPU2, rxdesc+misc -> CPU3
  # - RPS/XPS WAN/IFB -> CPU2+CPU3 (balancea carga sin tocar Wi-Fi)
  log "OPT: aplicando OFICIAL y luego optimización SOLO CABLE (no Wi-Fi)."
  apply_official

  cpu2=2
  cpu3=3
  m2="$(cpu_mask "$cpu2")"
  m3="$(cpu_mask "$cpu3")"
  m23="$(cpus_to_mask 2 3)"   # normalmente "c"

  # EDMA split (cable)
  for irq in $(irq_ids_by_name 'edma_txcmpl'); do set_irq_mask "$irq" "$m2"; done
  for irq in $(irq_ids_by_name 'edma_rxfill'); do set_irq_mask "$irq" "$m2"; done
  for irq in $(irq_ids_by_name 'edma_rxdesc'); do set_irq_mask "$irq" "$m3"; done
  for irq in $(irq_ids_by_name 'edma_misc');   do set_irq_mask "$irq" "$m3"; done

  # RPS/XPS SOLO WAN-ish (no wifi)
  for dev in $(wan_devs_detect); do
    set_rps_xps_dev "$dev" "$m23" "$m23"
  done

  log "OPT: listo. (Wi-Fi no fue tocado)."
}

# --- MONITOR (en vivo, Ctrl+C funciona) ---
snapshot_softirqs() {
  # output: KEY VALUE (total across CPUs)
  awk '
    $1 ~ /^(NET_RX:|NET_TX:|TASKLET:|SCHED:|RCU:|HI:|TIMER:|BLOCK:)/ {
      key=$1; sub(":","",key);
      s=0; for(i=2;i<=NF;i++) s+=$i;
      print key, s
    }
  ' /proc/softirqs 2>/dev/null || true
}

snapshot_irqs() {
  # output: KEY VALUE (total across CPUs) for selected patterns
  # KEY = IRQNUM:NAME
  c=$(ncpus)
  awk -v c="$c" '
    $1 ~ /^[0-9]+:$/ {
      name=$NF
      if (name ~ /(edma_|wbm2host|reo2host|ppdu-end|rxdma2host|host2rxdma|ce[0-9]+)/) {
        irq=$1; sub(":","",irq)
        s=0
        for(i=2;i<=1+c;i++) s+=$i
        print irq ":" name, s
      }
    }
  ' /proc/interrupts 2>/dev/null || true
}

diff_kv() {
  # diff_kv prev cur -> prints only non-zero deltas
  prev="$1"
  cur="$2"
  awk '
    NR==FNR {a[$1]=$2; next}
    {
      d=$2 - ( ($1 in a) ? a[$1] : 0 )
      if (d != 0) printf "%-34s +%d\n", $1, d
    }
  ' "$prev" "$cur"
}

monitor() {
  mkdir -p "$STATE_DIR"
  [ -f "$LOCK_FILE" ] && die "Monitor ya está corriendo (lock: $LOCK_FILE)"
  echo $$ > "$LOCK_FILE"

  cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
    exit 0
  }
  trap cleanup INT TERM

  prevS="${STATE_DIR}/soft.prev"
  curS="${STATE_DIR}/soft.cur"
  prevI="${STATE_DIR}/irq.prev"
  curI="${STATE_DIR}/irq.cur"

  snapshot_softirqs > "$prevS"
  snapshot_irqs     > "$prevI"

  while :; do
    sleep 1

    snapshot_softirqs > "$curS"
    snapshot_irqs     > "$curI"

    echo
    echo "============================================================"
    echo "== $(date '+%F %T') == (deltas por 1s)"
    echo "------------------------------------------------------------"
    echo "-- softirqs delta (NET_RX/NET_TX/TASKLET/SCHED/RCU/...) --"
    diff_kv "$prevS" "$curS" | sed 's/^/  /' || true

    echo
    echo "-- IRQ delta (edma + wifi datapath) --"
    diff_kv "$prevI" "$curI" | sed 's/^/  /' || true

    echo
    echo "-- afinidad CABLE (edma_*) ahora --"
    show_irqs_filtered 'edma_' | sed 's/^/  /'

    mv "$curS" "$prevS"
    mv "$curI" "$prevI"
  done
}

usage() {
  cat <<EOF
Uso:
  $0 status
  $0 factory-reset       (limpieza fuerte: affinity_hint + RPS/XPS=0 en todo)
  $0 apply-official      (OpenWrt smp_affinity IPQ807x)
  $0 apply-opt           (oficial + optimización SOLO CABLE, no toca Wi-Fi)
  $0 restore-state       (revierte SOLO lo que este script tocó)
  $0 monitor             (en vivo; Ctrl+C sale)

Notas:
  - NO reinicia servicios, NO toca tc/qdisc (no interrumpe QoSMate).
  - apply-opt NO toca IRQs de Wi-Fi ni RPS/XPS de Wi-Fi (solo WAN/IFB + edma).
EOF
}

main() {
  need_root
  cmd="${1:-}"
  case "$cmd" in
    status) shift; status ;;
    factory-reset) shift; factory_reset ;;
    apply-official) shift; apply_official ;;
    apply-opt) shift; apply_opt_cable ;;
    restore-state) shift; restore_state_only ;;
    monitor) shift; monitor ;;
    ""|-h|--help|help) usage ;;
    *) die "Comando desconocido: $cmd (usa --help)" ;;
  esac
}

main "$@"

