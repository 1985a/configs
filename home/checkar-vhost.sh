#!/bin/bash
set -euo pipefail

VM_NAME="${1:-win10}"
PIDFILE="/var/run/libvirt/qemu/${VM_NAME}.pid"
VM_CPUS_RANGE="${VM_CPUS_RANGE:-2-11}"   # puedes exportar otra cosa si cambias
RPSXPS_EXPECT_MASK="${RPSXPS_EXPECT_MASK:-ffc}"  # 2..11 => ffc en un host 0..11

RED() { echo -e "\e[31m$*\e[0m"; }
GRN() { echo -e "\e[32m$*\e[0m"; }
YEL() { echo -e "\e[33m$*\e[0m"; }

fail=0

if [[ ! -f "$PIDFILE" ]]; then
  RED "[X] No existe $PIDFILE. ¿La VM está encendida?"
  exit 2
fi

PID=$(cat "$PIDFILE")
if ! ps -p "$PID" &>/dev/null; then
  RED "[X] Proceso QEMU ($PID) no está activo."
  exit 2
fi

echo "== Verificando vhost pinning para VM=${VM_NAME} (PID=$PID), rango esperado: ${VM_CPUS_RANGE} =="

# 1) HILOS VHOST
bad_vhost=0
while read -r tid psr comm; do
  # tid psr comm (omitimos encabezado)
  [[ "$tid" =~ ^[0-9]+$ ]] || continue
  if [[ "$comm" =~ ^vhost- ]]; then
    cpu=$psr
    if [[ $cpu =~ ^([0-9]+)$ ]]; then
      # ¿cpu está dentro del rango?
      if ! awk -v c="$cpu" -v r="$VM_CPUS_RANGE" '
        function inrange(c,r,    s,e,i,n,ok,seg) {
          n=split(r,seg,",")
          for(i=1;i<=n;i++){
            if(seg[i] ~ /-/){ split(seg[i],a,"-"); s=a[1]; e=a[2]; if(c>=s && c<=e) return 1; }
            else { if(c==seg[i]) return 1; }
          }
          return 0
        }
        BEGIN { exit(inrange(c,r)?0:1) }'; then
        YEL "[!] vhost hilo TID=${tid} corriendo en CPU ${cpu} (fuera de ${VM_CPUS_RANGE})"
        bad_vhost=1
        fail=1
      fi
    fi
  fi
done < <(ps -T -p "$PID" -o tid,psr,comm)

if [[ $bad_vhost -eq 0 ]]; then
  GRN "[OK] Todos los hilos vhost-* están dentro de ${VM_CPUS_RANGE}"
fi

# 2) IRQs vnet/virtio
echo "== Verificando IRQs de vnet/virtio =="
bad_irq=0
while read -r irq rest; do
  irq=${irq%:}
  [[ "$irq" =~ ^[0-9]+$ ]] || continue
  aff=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null || echo "?")
  if [[ "$aff" != "$VM_CPUS_RANGE" ]]; then
    YEL "[!] IRQ ${irq} afinidad=${aff} (esperado=${VM_CPUS_RANGE})"
    bad_irq=1
    fail=1
  fi
done < <(grep -E 'vnet|virtio' /proc/interrupts || true)

[[ $bad_irq -eq 0 ]] && GRN "[OK] Afinidad de IRQs vnet/virtio correcta"

# 3) RPS/XPS masks
echo "== Verificando RPS/XPS (esperado mask=${RPSXPS_EXPECT_MASK}) =="
bad_rps=0
for f in /sys/class/net/br0/queues/rx-*/rps_cpus /sys/class/net/vnet*/queues/rx-*/rps_cpus; do
  [[ -e "$f" ]] || continue
  m=$(cat "$f")
  if [[ "$m" != "$RPSXPS_EXPECT_MASK" ]]; then
    YEL "[!] RPS $f = $m (esperado=${RPSXPS_EXPECT_MASK})"
    bad_rps=1
    fail=1
  fi
done

bad_xps=0
for f in /sys/class/net/br0/queues/tx-*/xps_cpus /sys/class/net/vnet*/queues/tx-*/xps_cpus; do
  [[ -e "$f" ]] || continue
  m=$(cat "$f")
  if [[ "$m" != "$RPSXPS_EXPECT_MASK" ]]; then
    YEL "[!] XPS $f = $m (esperado=${RPSXPS_EXPECT_MASK})"
    bad_xps=1
    fail=1
  fi
done

[[ $bad_rps -eq 0 && $bad_xps -eq 0 ]] && GRN "[OK] RPS/XPS coinciden con la máscara esperada"

if [[ $fail -eq 0 ]]; then
  GRN "== Todo OK =="
else
  YEL "== Hay elementos a corregir =="
fi
exit $fail

