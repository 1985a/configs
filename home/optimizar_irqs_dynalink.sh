#!/bin/sh
# irq_rps_tune_dlx36.sh
# Dynalink DL-WRX36 (IPQ807x / 4 cores) - IRQ affinity + RPS/XPS tuning for low latency
# Safe for QoSMate: does NOT touch tc/qdisc, does NOT restart services.
# BusyBox ash compatible.

set -eu

STATE_DIR="/tmp/irq_rps_tune_dlx36"
STATE_FILE="$STATE_DIR/state"
LOGTAG="irq_rps_tune_dlx36"

# --- CPU masks (hex) for 4 cores ---
# CPU0 se deja libre para el sistema (por eso no hay máscara para él)
CPU1_MASK="2"   # CPU1
CPU2_MASK="4"   # CPU2
CPU3_MASK="8"   # CPU3

# Targets (can be adjusted)
WIFI_CPU_A="$CPU1_MASK"  # Wi-Fi group A
WIFI_CPU_B="$CPU3_MASK"  # Wi-Fi group B
WAN_CPU="$CPU2_MASK"     # WAN/SQM path

# Interfaces (based on your ip -br link screenshots)
WAN_IFS="wan br-wan ifb-wan"
WIFI2G_IFS="lan2g guest2g"
WIFI5G_IFS="lan5g guest5g"

# If you want to avoid RPS/XPS changes, set to 0 (or run with --no-rpsxps)
DO_RPSXPS=1

# --- helpers ---
log() { logger -t "$LOGTAG" "$*"; echo "$*"; }

need_root() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root." >&2; exit 1; }
}

mkdir_state() {
  mkdir -p "$STATE_DIR"
  [ -f "$STATE_FILE" ] || : > "$STATE_FILE"
}

# Save original file content once (so we can restore)
save_once() {
  f="$1"
  [ -e "$f" ] || return 0
  # save only if not already saved
  if ! grep -q "^$f " "$STATE_FILE" 2>/dev/null; then
    val="$(cat "$f" 2>/dev/null || true)"
    printf "%s %s\n" "$f" "$val" >> "$STATE_FILE"
  fi
}

restore_all() {
  [ -f "$STATE_FILE" ] || { echo "No saved state to restore."; return 0; }
  while read -r f v; do
    [ -e "$f" ] || continue
    # some values might be empty; still try
    echo "$v" > "$f" 2>/dev/null || true
  done < "$STATE_FILE"
  rm -f "$STATE_FILE"
  log "RESTORE done. (state cleared)"
}

# Find IRQ numbers whose line contains a pattern
# Returns list of IRQ numbers (without ':')
find_irqs() {
  pat="$1"
  awk -v p="$pat" '$0 ~ p {gsub(":","",$1); print $1}' /proc/interrupts
}

# Set IRQ affinity safely
set_irq_affinity() {
  irq="$1"
  mask="$2"
  f="/proc/irq/$irq/smp_affinity"

  [ -e "$f" ] || return 0
  save_once "$f"
  echo "$mask" > "$f" 2>/dev/null || true
}

# Set RPS/XPS safely on device queues
set_rps_xps() {
  dev="$1"
  rps="$2"
  xps="$3"

  [ -d "/sys/class/net/$dev" ] || return 0

  for q in /sys/class/net/"$dev"/queues/rx-*; do
    [ -e "$q/rps_cpus" ] || continue
    save_once "$q/rps_cpus"
    echo "$rps" > "$q/rps_cpus" 2>/dev/null || true
  done

  for q in /sys/class/net/"$dev"/queues/tx-*; do
    [ -e "$q/xps_cpus" ] || continue
    save_once "$q/xps_cpus"
    echo "$xps" > "$q/xps_cpus" 2>/dev/null || true
  done
}

# Show current affinities for relevant IRQs
show_irq_status() {
  echo "== IRQ affinity (ath11k related) =="
  awk '
    /wbm2host|reo2host|ppdu-end|rxdma2host|host2rxdma|reo2ost|ce[0-9]+/ {
      irq=$1; sub(":","",irq);
      printf "%-5s %s\n", irq, $0
    }' /proc/interrupts | sed 's/ \+/ /g'

  echo
  echo "Masks (if available):"
  for irq in $(awk '/wbm2host|reo2host|ppdu-end|rxdma2host|host2rxdma|reo2ost/ {gsub(":","",$1); print $1}' /proc/interrupts); do
    f="/proc/irq/$irq/smp_affinity"
    [ -e "$f" ] || continue
    printf " IRQ %-4s mask=%s\n" "$irq" "$(cat "$f" 2>/dev/null || echo '?')"
  done
}

show_rps_status() {
  echo "== RPS/XPS status =="
  for dev in $WAN_IFS $WIFI2G_IFS $WIFI5G_IFS; do
    [ -d "/sys/class/net/$dev/queues" ] || continue
    echo "-- $dev --"
    for q in /sys/class/net/"$dev"/queues/rx-*; do
      [ -e "$q/rps_cpus" ] && echo "  $(basename "$q") rps=$(cat "$q/rps_cpus" 2>/dev/null)"
    done
    for q in /sys/class/net/"$dev"/queues/tx-*; do
      [ -e "$q/xps_cpus" ] && echo "  $(basename "$q") xps=$(cat "$q/xps_cpus" 2>/dev/null)"
    done
  done
}

# --- main apply steps ---
apply_irq_affinity() {
  # Strategy:
  # - Move heavy ath11k datapath IRQs away from CPU0.
  # - Split into two groups on CPU1/CPU3 to reduce single-core softirq spikes.
  #
  # Group A -> CPU1
  # Group B -> CPU3
  #
  # We select by name patterns (robust vs fixed IRQ numbers).

  # 1) RX release often heavy
  for irq in $(find_irqs "wbm2host-rx-release"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done

  # 2) TX completion rings: spread ring1 to CPU1, ring2/ring3 to CPU3
  for irq in $(find_irqs "wbm2host-tx-completions-ring1"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done
  for irq in $(find_irqs "wbm2host-tx-completions-ring2"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done
  for irq in $(find_irqs "wbm2host-tx-completions-ring3"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done

  # 3) PPDU end interrupts: split mac1 -> CPU1, mac3 -> CPU3 (common on IPQ807x)
  for irq in $(find_irqs "ppdu-end-interrupts-mac1"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done
  for irq in $(find_irqs "ppdu-end-interrupts-mac3"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done

  # 4) REO destination rings: split ring1/2 -> CPU1, ring3/4 -> CPU3
  for irq in $(find_irqs "reo2host-destination-ring1"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done
  for irq in $(find_irqs "reo2host-destination-ring2"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done
  for irq in $(find_irqs "reo2host-destination-ring3"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done
  for irq in $(find_irqs "reo2host-destination-ring4"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done

  # 5) Optional: keep some monitor/status IRQs off CPU0 as well (low risk)
  for irq in $(find_irqs "rxdma2host-monitor-status-ring-mac1"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done
  for irq in $(find_irqs "rxdma2host-monitor-status-ring-mac3"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done

  # 6) Optional: host2rxdma buf ring interrupts can be moved with their mac grouping
  for irq in $(find_irqs "host2rxdma-host-buf-ring-mac1"); do
    set_irq_affinity "$irq" "$WIFI_CPU_A"
  done
  for irq in $(find_irqs "host2rxdma-host-buf-ring-mac3"); do
    set_irq_affinity "$irq" "$WIFI_CPU_B"
  done
}

apply_rps_xps() {
  [ "$DO_RPSXPS" -eq 1 ] || { log "RPS/XPS skipped (--no-rpsxps)"; return 0; }

  # WAN/SQM path -> CPU2 (align with CAKE/SQM on ifb-wan)
  for dev in $WAN_IFS; do
    set_rps_xps "$dev" "$WAN_CPU" "$WAN_CPU"
  done

  # Wi-Fi -> align with the IRQ groups
  # 2.4 -> CPU1
  for dev in $WIFI2G_IFS; do
    set_rps_xps "$dev" "$WIFI_CPU_A" "$WIFI_CPU_A"
  done

  # 5G -> CPU3
  for dev in $WIFI5G_IFS; do
    set_rps_xps "$dev" "$WIFI_CPU_B" "$WIFI_CPU_B"
  done
}

dry_run() {
  echo "DRY RUN (no changes). Proposed settings:"
  echo "  Wi-Fi Group A (CPU1) mask: $WIFI_CPU_A"
  echo "  Wi-Fi Group B (CPU3) mask: $WIFI_CPU_B"
  echo "  WAN/SQM (CPU2) mask:       $WAN_CPU"
  echo
  echo "Would target IRQs matching:"
  echo "  wbm2host-rx-release"
  echo "  wbm2host-tx-completions-ring{1,2,3}"
  echo "  ppdu-end-interrupts-mac{1,3}"
  echo "  reo2host-destination-ring{1,2,3,4}"
  echo "  rxdma2host-monitor-status-ring-mac{1,3}"
  echo "  host2rxdma-host-buf-ring-mac{1,3}"
  echo
  echo "Would set RPS/XPS on:"
  echo "  WAN:   $WAN_IFS -> $WAN_CPU"
  echo "  2.4G:  $WIFI2G_IFS -> $WIFI_CPU_A"
  echo "  5G:    $WIFI5G_IFS -> $WIFI_CPU_B"
}

apply_all() {
  mkdir_state
  apply_irq_affinity
  apply_rps_xps
  log "APPLY done."
}

usage() {
  cat <<EOF
Usage:
  $0 apply           Apply IRQ affinity + (optional) RPS/XPS
  $0 status          Show current relevant IRQs and RPS/XPS
  $0 dry-run         Show what would be applied (no changes)
  $0 restore         Restore previous saved values from $STATE_FILE
  $0 apply --no-rpsxps   Apply only IRQ affinity (skip RPS/XPS)
Notes:
  - Safe for QoSMate: does NOT touch tc/qdisc.
  - Values are saved before first change and can be restored.
EOF
}

# --- entrypoint ---
need_root

CMD="${1:-}"
case "$CMD" in
  apply)
    if [ "${2:-}" = "--no-rpsxps" ]; then
      DO_RPSXPS=0
    fi
    apply_all
    ;;
  status)
    show_irq_status
    echo
    show_rps_status
    ;;
  dry-run)
    dry_run
    ;;
  restore)
    restore_all
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "Unknown command: $CMD" >&2
    usage
    exit 1
    ;;
esac

